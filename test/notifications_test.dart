import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:runner_remote/core/core.dart';
import 'package:runner_remote/core/store.dart';
import 'package:runner_remote/pages/notifications.dart';
import 'package:runner_remote/services.dart';

import 'widget_test.dart' show FakeCore;

/// A server with NotifyService: a saved Bark channel and one computer.
class NotifyCore extends FakeCore {
  Map<String, Object?> settings = {
    'channel': {
      'kind': 'bark',
      'server': 'https://api.day.app',
      'deviceKey': 'key1',
      'group': '',
      'sound': '',
      'level': 'timeSensitive',
    },
    'events': {'input': true, 'finished': false, 'failed': true},
  };
  var paired = false;

  List<Map<String, Object?>> notified(String method) => [
    for (final (op, args) in calls)
      if (op == 'notify' && args['method'] == method)
        args['body'] as Map<String, Object?>,
  ];

  @override
  Future<dynamic> call(String op, Map<String, Object?> args) async {
    if (op != 'notify') return super.call(op, args);
    calls.add((op, args));
    final body = args['body'] as Map<String, Object?>;
    switch (args['method']) {
      case 'GetSettings':
        return settings;
      case 'SetSettings':
        return settings = body;
      case 'Test':
        if (settings['channel'] == null) throw CoreException('还没有设置推送方式');
        return {};
      case 'ListWatchers':
        return {
          'watchers': [
            {
              'computer': '42',
              'name': 'studio',
              'online': true,
              'paired': paired,
              'watching': paired,
              'error': null,
            },
          ],
        };
      case 'PairWatcher':
        if (body['pin'] != '123456') throw CoreException('PIN 不正确');
        paired = true;
        return {};
    }
    return {};
  }
}

Future<NotifyCore> _open(WidgetTester tester) async {
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 4000);
  addTearDown(tester.view.reset);
  final core = NotifyCore();
  await tester.pumpWidget(
    Services(
      core: core,
      store: Store(),
      child: MaterialApp(
        home: NotificationsPage(
          account: Account(
            id: 'a1',
            origin: 'https://r.example',
            credential: 'c',
            username: 'alice',
            serverVersion: 'v0.1.2(7)-1a2b3c',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return core;
}

void main() {
  test('parses header lines', () {
    expect(
      parseHeaders('Authorization: Bearer x:y\n\nbad line\n X-A :1 \n:skip'),
      {'Authorization': 'Bearer x:y', 'X-A': '1'},
    );
    expect(formatHeaders({'A': 'b', 'C': 'd'}), 'A: b\nC: d');
  });

  testWidgets('shows, changes and saves the settings', (tester) async {
    final core = await _open(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('barkKey')))
          .controller!
          .text,
      'key1',
    );
    expect(find.text('studio'), findsOneWidget);
    expect(find.text('在线 · 未配对'), findsOneWidget);

    await tester.tap(find.text('Ntfy'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('ntfyTopic')), 'runner');
    await tester.tap(find.byKey(const Key('notifySave')));
    await tester.pumpAndSettle();
    final saved = core.notified('SetSettings').single;
    expect(saved['channel'], {
      'kind': 'ntfy',
      'server': 'https://ntfy.sh',
      'topic': 'runner',
      'token': '',
      'priority': 0,
      'tags': '',
    });
    expect(saved['events'], {'input': true, 'finished': false, 'failed': true});
    expect(find.text('已保存'), findsOneWidget);
  });

  testWidgets('pairs the server with a computer', (tester) async {
    final core = await _open(tester);
    await tester.tap(find.byKey(const Key('watcherPair.42')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('watcherPin')), '123456');
    await tester.tap(find.byKey(const Key('watcherPinOk')));
    await tester.pumpAndSettle();
    expect(core.notified('PairWatcher').single, {
      'computer': '42',
      'pin': '123456',
    });
    expect(find.text('在线 · 监听中'), findsOneWidget);
  });
}
