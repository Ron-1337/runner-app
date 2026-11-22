import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:runner_remote/core/core.dart';
import 'package:runner_remote/core/store.dart';
import 'package:runner_remote/main.dart';
import 'package:runner_remote/pages/sign_in.dart';
import 'package:runner_remote/services.dart';
import 'package:xterm/xterm.dart';

/// Answers the commands the app sends, like the Rust core with a computer behind it.
class FakeCore extends Core {
  final calls = <(String, Map<String, Object?>)>[];
  final _routes = StreamController<RouteEvent>.broadcast();
  var approved = false;

  /// What runner-server says it is when it approves; null as the official service.
  String? serverVersion;

  /// The account has no computers; the official service then answers `{}`.
  var noComputers = false;

  @override
  Stream<RouteEvent> get routeEvents => _routes.stream;

  void push(Map<String, dynamic> message) =>
      _routes.add(RouteEvent(1, message));

  List<Map<String, Object?>> requests(String type) => [
    for (final (op, args) in calls)
      if (op == 'request' &&
          (args['message'] as Map<String, Object?>)['type'] == type)
        args['message'] as Map<String, Object?>,
  ];

  @override
  Future<dynamic> call(String op, Map<String, Object?> args) async {
    calls.add((op, args));
    switch (op) {
      case 'startEnrollment':
        return {
          'deviceCode': 'device-code',
          'userCode': 'BCDF-GHJK',
          'verificationUriComplete':
              'https://runner.example.com/hosts/add?code=BCDF-GHJK',
          'interval': 1,
        };
      case 'pollEnrollment':
        return approved
            ? {
                'state': 'ENROLLMENT_STATE_APPROVED',
                'credential': 'rcc_secret',
                'account': {'username': 'alice'},
                'serverVersion': ?serverVersion,
              }
            : {'state': 'ENROLLMENT_STATE_PENDING'};
      case 'listComputers':
        if (noComputers) return <String, dynamic>{};
        return {
          'hosts': [
            {
              'id': '42',
              'name': 'studio',
              'online': true,
              'fingerprint': 'aaaa bbbb cccc dddd eeee',
              'info': {'platform': 'linux'},
            },
          ],
        };
      case 'pair':
        if (args['pin'] != '482917') throw CoreException('PIN 不正确');
        return {
          'route': 1,
          'clientKey': 'client',
          'hostKey': 'host',
          'welcome': {'name': 'studio'},
        };
      case 'request':
        final message = args['message'] as Map<String, Object?>;
        if (message['type'] == 'overview') {
          return {
            'projects': [],
            'tabs': [],
            'missions': [],
            'sessions': {
              's1': {
                'kind': 'chat',
                'title': 'Fix the build',
                'runtime': 'claude',
                'status': 'needsYou',
                'unread': true,
              },
            },
          };
        }
        return null;
    }
    return null;
  }
}

/// Pumps a dialog open; the tile behind it shows a spinner, so it never settles.
Future<void> openDialog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// URLs the sign-in browser was opened at; it stays open, as a person reading
/// the page would leave it.
final browsed = <String>[];

void main() {
  setUp(() {
    browsed.clear();
    openSignInBrowser = (url) {
      browsed.add(url);
      return Completer<void>().future;
    };
  });

  test('validateOrigin accepts HTTPS and HTTP', () {
    expect(validateOrigin('https://runner.example.com'), isNull);
    expect(validateOrigin('http://localhost:8080'), isNull);
    expect(validateOrigin('http://runner.example.com'), isNull);
    expect(validateOrigin('ftp://runner.example.com'), isNotNull);
    expect(validateOrigin('runner.example.com'), isNotNull);
  });

  testWidgets('shows an error for an address that is not HTTP(S)', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(RunnerApp(core: FakeCore(), store: Store()));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('origin')),
      'ftp://example.com',
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(find.text('只支持 HTTPS 或 HTTP 地址'), findsOneWidget);
  });

  testWidgets('an HTTP address is confirmed, after a second', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final core = FakeCore();
    await tester.pumpWidget(RunnerApp(core: core, store: Store()));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('origin')),
      'http://192.168.1.5:8080',
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(find.textContaining('未加密'), findsWidgets);
    FilledButton proceed() =>
        tester.widget<FilledButton>(find.byKey(const Key('httpProceed')));
    expect(proceed().onPressed, isNull, reason: 'held for a second');
    await tester.pump(const Duration(milliseconds: 1100));
    expect(proceed().onPressed, isNotNull);

    // Cancelling stays on the page and starts nothing.
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(core.calls.where((c) => c.$1 == 'startEnrollment'), isEmpty);

    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.tap(find.byKey(const Key('httpProceed')));
    // The code page spins while it waits, so it never settles.
    await tester.pump(const Duration(milliseconds: 500));
    final start = core.calls.lastWhere((c) => c.$1 == 'startEnrollment');
    expect(start.$2['origin'], 'http://192.168.1.5:8080');
  });

  /// Signs in to [core] until it approves; returns the saved account.
  Future<Account> signIn(
    WidgetTester tester,
    FakeCore core,
    Store store,
  ) async {
    await tester.pumpWidget(RunnerApp(core: core, store: store));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('origin')),
      'https://runner.example.com',
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    core.approved = true;
    await tester.pump(const Duration(seconds: 1));
    // A warning would open over the waiting spinner, which never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    return (await store.accounts()).single;
  }

  testWidgets('runner-server of the same version signs in without a warning', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = Store();
    // Another build of the same release: the server and app build apart.
    final release = releaseVersion(knownDeviceInfo()['appVersion'] as String);
    final core = FakeCore()..serverVersion = 'v$release(99)-ffffff';
    final account = await signIn(tester, core, store);
    expect(account.serverVersion, core.serverVersion);
    expect(account.official, isFalse);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('versionMismatch')), findsNothing);
    expect(find.text('studio'), findsOneWidget);
  });

  testWidgets('an account without computers on the official service loads', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = Store();
    final core = FakeCore()..noComputers = true;
    final account = await signIn(tester, core, store);
    expect(account.official, isTrue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('subtype'), findsNothing);
    expect(find.text('studio'), findsNothing);
  });

  testWidgets('runner-server of another version warns, then carries on', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = Store();
    final core = FakeCore()..serverVersion = 'v9.9.9(3)-abcdef';
    final account = await signIn(tester, core, store);
    expect(account.serverVersion, 'v9.9.9(3)-abcdef');
    expect(find.byKey(const Key('versionMismatch')), findsOneWidget);
    expect(
      find.textContaining('Runner-Server v9.9.9(3)-abcdef'),
      findsOneWidget,
    );
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('versionMismatch')), findsNothing);
    expect(find.text('studio'), findsOneWidget);
  });

  test('versions read vX.Y.Z(B)-commit and compare by release', () {
    expect(versionLabel('0.1.2'), 'v0.1.2(0)-000000', reason: 'a local build');
    expect(releaseVersion('v0.1.2(57)-1a2b3c'), '0.1.2');
    expect(releaseVersion('0.1.2+4'), '0.1.2');
    expect(releaseVersion('0.1.2'), '0.1.2');
  });

  testWidgets('signs in, pairs by PIN and types into a terminal', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final core = FakeCore();
    final store = Store();
    await tester.pumpWidget(RunnerApp(core: core, store: store));
    await tester.pumpAndSettle();

    // Sign in: the code shows while the person approves it in a browser.
    await tester.enterText(
      find.byKey(const Key('origin')),
      'https://runner.example.com',
    );
    final name = find.byKey(const Key('deviceName'));
    expect(
      tester.widget<TextField>(name).controller!.text,
      isNotEmpty,
      reason: 'the name defaults to the model',
    );
    await tester.enterText(name, '  Work phone ');
    await tester.tap(find.byType(FilledButton));
    // The waiting spinner never settles, so pump through the page transition.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('BCDF-GHJK'), findsOneWidget);
    final start = core.calls.lastWhere((c) => c.$1 == 'startEnrollment');
    expect((start.$2['device'] as Map)['name'], 'Work phone');
    expect(browsed, hasLength(1), reason: 'opens the approval page itself');
    expect(Uri.parse(browsed.single).queryParameters['app'], '1');
    await tester.pump(const Duration(seconds: 1));
    expect(core.calls.last.$1, 'pollEnrollment', reason: 'still pending');
    expect(find.text('BCDF-GHJK'), findsOneWidget);
    core.approved = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final account = (await store.accounts()).single;
    expect(account.credential, 'rcc_secret');
    expect(account.official, isTrue, reason: 'no serverVersion');
    expect(find.byKey(const Key('versionMismatch')), findsNothing);
    expect(find.text('alice@runner.example.com'), findsOneWidget);

    // Pair: a wrong PIN is reported, the right one opens the computer.
    expect(find.text('studio'), findsOneWidget);
    await tester.tap(find.text('studio'));
    await openDialog(tester);
    await tester.enterText(find.byKey(const Key('pin')), '000000');
    await tester.tap(find.text('配对'));
    await tester.pumpAndSettle();
    expect(find.text('PIN 不正确'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // Let the snackbar expire.
    await tester.pumpAndSettle();
    expect(await store.pairing(account, '42'), isNull);

    await tester.tap(find.text('studio'));
    await openDialog(tester);
    await tester.enterText(find.byKey(const Key('pin')), '482917');
    await tester.tap(find.text('配对'));
    await tester.pumpAndSettle();
    final pairing = (await store.pairing(account, '42'))!;
    expect(pairing.hostKey, 'host');
    expect(pairing.fingerprint, 'aaaa bbbb cccc dddd eeee');
    expect(find.text('Fix the build'), findsOneWidget);
    expect(find.textContaining('需要你'), findsOneWidget);

    // Open the session: it attaches at the view's size and taking control.
    await tester.tap(find.text('Fix the build'));
    await tester.pumpAndSettle();
    final attach = core.requests('attach').single;
    expect(attach['session'], 's1');
    expect(attach['control'], 'take');
    expect(attach['cols'], greaterThan(0));

    // Output arrives split inside a multi-byte character.
    final bytes = utf8.encode('\$ 你好');
    core.push({
      'type': 'snapshot',
      'session': 's1',
      'seq': 0,
      'more': true,
      'data': base64Encode(bytes.sublist(0, 4)),
    });
    core.push({
      'type': 'snapshot',
      'session': 's1',
      'seq': 1,
      'more': false,
      'data': base64Encode(bytes.sublist(4)),
    });
    await tester.pump();
    final terminal = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(terminal.terminal.buffer.lines[0].toString(), startsWith('\$ 你好'));

    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    terminal.terminal.textInput('c'); // From the phone keyboard.
    await tester.pumpAndSettle();
    expect(
      utf8.decode(
        base64Decode(core.requests('input').single['data'] as String),
      ),
      '\x03',
    );

    // The desktop took the terminal back: input stops until the phone takes it again.
    core.push({
      'type': 'resized',
      'session': 's1',
      'seq': 2,
      'cols': 120,
      'rows': 40,
      'controller': {'kind': 'desktop'},
    });
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('电脑桌面正在使用'), findsOneWidget);
    await tester.tap(find.text('接管'));
    await tester.pump();
    expect(core.requests('takeControl').single['session'], 's1');

    // Leaving detaches.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(core.requests('detach').single['session'], 's1');
  });
}
