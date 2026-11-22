import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:runner_remote/core/store.dart';
import 'package:runner_remote/main.dart';

import 'widget_test.dart' show FakeCore;

/// [FakeCore] with a computer that can be connected to without pairing again.
class PairedCore extends FakeCore {
  @override
  Future<dynamic> call(String op, Map<String, Object?> args) async {
    switch (op) {
      case 'connect':
        calls.add((op, args));
        return {
          'route': 7,
          'welcome': {
            'features': ['overview', 'usage'],
          },
        };
      case 'close':
        calls.add((op, args));
        return null;
      case 'request':
        final message = args['message'] as Map<String, Object?>;
        if (message['type'] == 'usage') {
          calls.add((op, args));
          return {
            'agents': [
              {
                'name': 'claude-code',
                'value': {
                  'windows': [
                    {'name': '5h', 'usedPercent': 34.0},
                    {'name': 'Week', 'usedPercent': 71.0},
                  ],
                  'updatedAt': '2026-11-22T10:00:00Z',
                },
              },
            ],
            'refreshing': false,
          };
        }
    }
    return super.call(op, args);
  }
}

Future<(PairedCore, Store)> home(WidgetTester tester) async {
  FlutterSecureStorage.setMockInitialValues({});
  final store = Store();
  final account = await store.addAccount(
    origin: 'https://runner.example.com',
    credential: 'rhc_secret',
    username: 'alice',
  );
  await store.savePairing(
    account,
    '42',
    Pairing(
      clientKey: 'client',
      hostKey: 'host',
      fingerprint: 'aaaa bbbb cccc dddd eeee',
    ),
  );
  final core = PairedCore();
  await tester.pumpWidget(RunnerApp(core: core, store: store));
  await tester.pumpAndSettle();
  return (core, store);
}

void main() {
  testWidgets('the dashboard sums up computers, sessions and usage', (
    tester,
  ) async {
    final (core, _) = await home(tester);
    expect(find.text('studio'), findsOneWidget);
    expect(core.calls.where((c) => c.$1 == 'connect'), isEmpty);

    await tester.tap(find.byKey(const Key('tabDashboard')));
    await tester.pumpAndSettle();
    String stat(String key) =>
        (tester.widget<Column>(find.byKey(Key(key))).children.first as Text)
            .data!;
    expect(stat('statOnline'), '1');
    expect(stat('statOffline'), '0');
    expect(stat('statNeedsYou'), '1');
    expect(find.byKey(const Key('dashboardSession-s1')), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('34%'), findsOneWidget);
    expect(find.text('71%'), findsOneWidget);
    // The route used for reading is closed again.
    expect(core.calls.where((c) => c.$1 == 'close'), hasLength(1));

    // A session opens on its computer.
    await tester.tap(find.byKey(const Key('dashboardSession-s1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('terminalSettings')), findsOneWidget);
  });

  testWidgets('settings change the font, the return key and the accounts', (
    tester,
  ) async {
    final (_, store) = await home(tester);
    await tester.tap(find.byKey(const Key('tabSettings')));
    await tester.pumpAndSettle();
    expect(find.text('alice@runner.example.com'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settingsFontLarger')));
    await tester.pumpAndSettle();
    expect(await store.terminalFontSize(), 14);
    await tester.tap(find.byKey(const Key('settingsFontReset')));
    await tester.pumpAndSettle();
    expect(await store.terminalFontSize(), 13);

    expect(await store.keyboardEnterSends(), isFalse, reason: 'new line');
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(await store.keyboardEnterSends(), isTrue);

    await tester.tap(find.byKey(const Key('settingsAddAccount')));
    await tester.pumpAndSettle();
    expect(find.text('添加账户'), findsOneWidget);
  });
}
