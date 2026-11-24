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

Future<(PairedCore, Store)> home(
  WidgetTester tester, {
  String? serverVersion,
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  final store = Store();
  final account = await store.addAccount(
    origin: 'https://runner.example.com',
    credential: 'rhc_secret',
    serverVersion: serverVersion,
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

/// Scrolls the settings until [finder] is at the top, clear of the bottom bar.
/// [up] when it lies above what is showing.
Future<void> reveal(
  WidgetTester tester,
  Finder finder, {
  bool up = false,
}) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, up ? -200 : 200);
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
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
    await reveal(tester, find.text('alice@runner.example.com'));
    expect(find.text('alice@runner.example.com'), findsOneWidget);
    // Back to the top, where 恢复默认 sits above the font size.
    await reveal(tester, find.byKey(const Key('settingsFontReset')), up: true);

    await tester.tap(find.byKey(const Key('settingsFontLarger')));
    await tester.pumpAndSettle();
    expect(await store.terminalFontSize(), 14);
    await tester.tap(find.byKey(const Key('settingsFontReset')));
    await tester.pumpAndSettle();
    expect(await store.terminalFontSize(), 13);

    expect(await store.keyboardEnterSends(), isFalse, reason: 'new line');
    await reveal(tester, find.text('发送'));
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(await store.keyboardEnterSends(), isTrue);

    // Font, cursor and showing it always are kept, and 恢复默认 resets them.
    await reveal(
      tester,
      find.byKey(const Key('settingsFont.system')),
      up: true,
    );
    await tester.tap(find.byKey(const Key('settingsFont.system')));
    await tester.pumpAndSettle();
    expect(await store.terminalFont(), TerminalFont.system);
    await reveal(tester, find.text('竖线'));
    await tester.tap(find.text('竖线'));
    await tester.pumpAndSettle();
    expect(await store.terminalCursor(), TerminalCursor.bar);
    await reveal(
      tester,
      find.byKey(const Key('settingsTerminalPreview')),
      up: true,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('settingsTerminalPreview')),
        matching: find.textContaining('▏'),
      ),
      findsOneWidget,
    );
    await reveal(tester, find.byKey(const Key('settingsCursorAlways')));
    await tester.tap(find.byKey(const Key('settingsCursorAlways')));
    await tester.pumpAndSettle();
    expect(await store.terminalCursorAlways(), isTrue);
    await reveal(tester, find.byKey(const Key('settingsFontReset')), up: true);
    await tester.tap(find.byKey(const Key('settingsFontReset')));
    await tester.pumpAndSettle();
    expect(await store.terminalFont(), TerminalFont.jetBrainsMono);
    expect(await store.terminalCursor(), TerminalCursor.block);
    expect(await store.terminalCursorAlways(), isFalse);

    await reveal(tester, find.byKey(const Key('settingsAddAccount')));
    await tester.tap(find.byKey(const Key('settingsAddAccount')));
    await tester.pumpAndSettle();
    expect(find.text('添加账户'), findsOneWidget);
  });

  testWidgets(
    'settings call the official service so and offer no notifications',
    (tester) async {
      final (core, _) = await home(tester);
      await tester.tap(find.byKey(const Key('tabSettings')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.textContaining('官方服务器'), 200);
      expect(find.textContaining('官方服务器'), findsOneWidget);
      // The section would sit just above 关于, below the fold.
      await tester.scrollUntilVisible(find.text('关于'), 300);
      expect(find.text('推送通知'), findsNothing, reason: 'it has none');
      expect(core.calls.where((c) => c.$1 == 'notify'), isEmpty);
    },
  );

  testWidgets(
    'settings name Runner-Server with its version and offer notifications',
    (tester) async {
      await home(tester, serverVersion: 'v0.1.2(7)-1a2b3c');
      await tester.tap(find.byKey(const Key('tabSettings')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('Runner-Server v0.1.2(7)-1a2b3c'),
        200,
      );
      expect(
        find.textContaining('Runner-Server v0.1.2(7)-1a2b3c'),
        findsOneWidget,
      );
      expect(find.textContaining('自建'), findsNothing);
      await tester.scrollUntilVisible(find.text('推送通知'), 300);
      expect(find.text('推送通知'), findsOneWidget);
    },
  );
}
