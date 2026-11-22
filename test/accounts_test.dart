import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:runner_remote/core/links.dart';
import 'package:runner_remote/core/store.dart';
import 'package:runner_remote/main.dart';

import 'widget_test.dart' show FakeCore, openDialog;

final _pairing = Pairing(clientKey: 'c', hostKey: 'h', fingerprint: 'f');

void main() {
  group('Store', () {
    test('moves the single account and its pairings over', () async {
      FlutterSecureStorage.setMockInitialValues({
        'account': jsonEncode({
          'origin': 'https://r.example',
          'credential': 'rhc_old',
          'username': 'alice',
        }),
        'pairing.42': jsonEncode(_pairing.toJson()),
      });
      final store = Store();
      final account = (await store.accounts()).single;
      expect(account.username, 'alice');
      expect(account.credential, 'rhc_old');
      expect((await store.pairing(account, '42'))!.hostKey, 'h');
      final keys = (await const FlutterSecureStorage().readAll()).keys;
      expect(keys, isNot(contains('account')));
      expect(keys, isNot(contains('pairing.42')));
      expect((await store.accounts()).single.id, account.id);
    });

    test('keeps accounts and their pairings apart', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = Store();
      final alice = await store.addAccount(
        origin: 'https://a.example',
        credential: '1',
        username: 'alice',
      );
      final bob = await store.addAccount(
        origin: 'https://b.example',
        credential: '2',
        username: 'bob',
      );
      expect(alice.id, isNot(bob.id));
      await store.savePairing(alice, '42', _pairing);
      expect(await store.pairing(bob, '42'), isNull);

      // Signing in again replaces the credential and keeps the pairing.
      final again = await store.addAccount(
        origin: 'https://a.example/',
        credential: '3',
        username: 'alice',
      );
      expect(again.id, alice.id);
      expect((await store.accounts()).map((a) => a.credential), ['3', '2']);
      expect(await store.pairing(again, '42'), isNotNull);

      await store.savePairing(bob, '7', _pairing);
      await store.removeAccount(again);
      expect((await store.accounts()).single.username, 'bob');
      expect(await store.pairing(again, '42'), isNull);
      expect(await store.pairing(bob, '7'), isNotNull);
    });
  });

  test('parses links', () {
    final add = AppLink.parse(
      Uri.parse('runner-remote://add?server=https://r.example'),
    );
    expect((add as AddAccountLink).server, 'https://r.example');
    expect(
      AppLink.parse(Uri.parse('runner-remote:/add')),
      isA<AddAccountLink>(),
    );

    final open = AppLink.parse(
      Uri.parse(
        'runner-remote://open?server=https%3A%2F%2Fr.example&computer=42&user=bob',
      ),
    );
    expect(open, isA<OpenComputerLink>());
    open as OpenComputerLink;
    expect(open.server, 'https://r.example');
    expect(open.computer, '42');
    expect(open.username, 'bob');

    expect(
      AppLink.parse(Uri.parse('runner-remote://open?computer=42')),
      isNull,
      reason: 'no server',
    );
    final list =
        AppLink.parse(
              Uri.parse('runner-remote://open?server=https://r.example'),
            )
            as OpenComputerLink;
    expect(list.computer, isNull);
    final notified =
        AppLink.parse(
              Uri.parse(
                'runner-remote://open?server=https://r.example&computer=42&session=s1',
              ),
            )
            as OpenComputerLink;
    expect(notified.session, 's1');
    expect(
      AppLink.parse(
        Uri.parse('runner-remote://open?server=ftp://r.example&computer=42'),
      ),
      isNull,
      reason: 'HTTPS or HTTP only',
    );
    expect(AppLink.parse(Uri.parse('https://r.example/add')), isNull);
    expect(AppLink.parse(Uri.parse('runner-remote://nope')), isNull);
  });

  Future<(Store, Account, Account)> twoAccounts() async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = Store();
    final alice = await store.addAccount(
      origin: 'https://a.example',
      credential: '1',
      username: 'alice',
    );
    final bob = await store.addAccount(
      origin: 'https://b.example',
      credential: '2',
      username: 'bob',
    );
    return (store, alice, bob);
  }

  testWidgets('lists every account and signs out of one', (tester) async {
    final (store, alice, _) = await twoAccounts();
    final core = FakeCore();
    await tester.pumpWidget(RunnerApp(core: core, store: store));
    await tester.pumpAndSettle();
    expect(find.text('alice@a.example'), findsOneWidget);
    expect(find.text('bob@b.example'), findsOneWidget);
    expect(find.text('studio'), findsNWidgets(2));
    expect(
      core.calls
          .where((c) => c.$1 == 'listComputers')
          .map((c) => c.$2['credential']),
      unorderedEquals(['1', '2']),
    );

    await tester.tap(find.byKey(Key('account.${alice.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(core.calls.any((c) => c.$1 == 'signOut'), isTrue);
    expect(find.text('alice@a.example'), findsNothing);
    expect(find.text('bob@b.example'), findsOneWidget);
    expect((await store.accounts()).single.username, 'bob');
  });

  testWidgets('a link fills in the server for another account', (tester) async {
    final (store, _, _) = await twoAccounts();
    final links = StreamController<Uri>();
    addTearDown(links.close);
    await tester.pumpWidget(
      RunnerApp(core: FakeCore(), store: store, links: links.stream),
    );
    await tester.pumpAndSettle();
    links.add(Uri.parse('runner-remote://add?server=https://c.example'));
    await tester.pumpAndSettle();
    expect(find.text('添加账户'), findsWidgets);
    final field = tester.widget<TextField>(find.byKey(const Key('origin')));
    expect(field.controller!.text, 'https://c.example');
  });

  testWidgets('a link opens a computer under the matching account', (
    tester,
  ) async {
    final (store, _, bob) = await twoAccounts();
    final core = FakeCore();
    final links = StreamController<Uri>();
    addTearDown(links.close);
    await tester.pumpWidget(
      RunnerApp(core: core, store: store, links: links.stream),
    );
    await tester.pumpAndSettle();
    links.add(
      Uri.parse('runner-remote://open?server=https://b.example&computer=42'),
    );
    await openDialog(tester);
    expect(find.byKey(const Key('pin')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('pin')), '482917');
    await tester.tap(find.text('配对'));
    await tester.pumpAndSettle();
    final pair = core.calls.lastWhere((c) => c.$1 == 'pair').$2;
    expect(pair['credential'], '2');
    expect(await store.pairing(bob, '42'), isNotNull);
    expect(find.text('Fix the build'), findsOneWidget);
  });
}
