import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:runner_app/core/core.dart';
import 'package:runner_app/core/remote.dart';
import 'package:runner_app/core/store.dart';
import 'package:runner_app/pages/computer.dart';
import 'package:runner_app/services.dart';

const allFeatures = [
  'overview',
  'catalog',
  'folders',
  'startChat',
  'startShell',
  'startMission',
  'stop',
  'resume',
  'restart',
  'rename',
  'archive',
  'createProject',
  'deleteProject',
  'stopMission',
  'resumeMission',
  'markViewed',
  'attach',
  'input',
  'takeControl',
  'viewport',
  'detach',
];

Map<String, dynamic> overview() => {
  'projects': [
    {'id': 'p1', 'name': 'runner'},
  ],
  'tabs': [
    {
      'id': 't1',
      'project': 'p1',
      'name': 'Fix',
      'pinned': false,
      'panes': {'session': 's1'},
      'shells': [],
    },
    {
      'id': 't2',
      'project': null,
      'name': 'Pair review',
      'pinned': false,
      'panes': {
        'split': 'row',
        'sizes': [0.5, 0.5],
        'a': {'session': 's2'},
        'b': {'session': 's3'},
      },
      'shells': [],
    },
  ],
  'missions': [
    {
      'id': 'm1',
      'project': 'p1',
      'title': 'Ship it',
      'crew': 'trio',
      'state': 'running',
      'pinned': false,
      'members': [
        {'handle': 'coder', 'session': 's4', 'lead': true},
      ],
      'asks': [],
      'shells': [],
    },
  ],
  'sessions': {
    's1': {
      'kind': 'chat',
      'title': 'Fix the build',
      'status': 'idle',
      'unread': true,
    },
    's2': {'kind': 'shell', 'title': '', 'status': 'stopped', 'unread': false},
    's3': {
      'kind': 'chat',
      'title': 'Review',
      'status': 'working',
      'unread': false,
    },
    's4': {
      'kind': 'agent',
      'title': 'Coder',
      'status': 'needsYou',
      'unread': false,
    },
  },
};

/// A computer behind a route: answers companion requests and records them.
class FakeComputer extends Core {
  final requests = <Map<String, Object?>>[];
  final _routes = StreamController<RouteEvent>.broadcast();
  final answers = <String, Object? Function(Map<String, Object?>)>{
    'overview': (_) => overview(),
    'catalog': (_) => {
      'roles': [],
      'runtimes': [
        {
          'name': 'claude',
          'label': 'Claude Code',
          'available': true,
          'models': [
            {'value': 'opus', 'label': 'Opus'},
          ],
        },
        {'name': 'codex', 'label': 'Codex', 'available': false, 'models': []},
      ],
      'accounts': [],
      'activeAccount': '',
      'crews': [
        {'id': 'c1', 'name': 'trio', 'slots': []},
      ],
      'projects': [
        {'id': 'p1', 'name': 'runner', 'path': '/home/alice/runner'},
      ],
      'recentFolders': [],
    },
    'folders': (m) => m['path'] == null
        ? {
            'path': '/home/alice',
            'parent': '/home',
            'folders': ['code'],
          }
        : {'path': m['path'], 'parent': '/home/alice', 'folders': []},
    'startChat': (_) => {'session': 's9'},
    'startShell': (_) => {'session': 's8'},
    'startMission': (_) => {'mission': 'm2'},
    'createProject': (_) => {'project': 'p2'},
    'resume': (m) => {'session': m['session']},
  };

  List<Map<String, Object?>> of(String type) =>
      requests.where((r) => r['type'] == type).toList();

  @override
  Stream<RouteEvent> get routeEvents => _routes.stream;

  @override
  Future<dynamic> call(String op, Map<String, Object?> args) async {
    if (op != 'request') return null;
    final message = args['message'] as Map<String, Object?>;
    requests.add(message);
    final answer = answers[message['type']];
    return answer?.call(message);
  }
}

Future<FakeComputer> open(
  WidgetTester tester, {
  List<String> features = allFeatures,
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  final core = FakeComputer();
  await tester.pumpWidget(
    Services(
      core: core,
      store: Store(),
      child: MaterialApp(
        home: ComputerPage(
          account: Account(
            origin: 'https://r.example',
            credential: 'c',
            username: 'alice',
          ),
          computer: const {'id': '42', 'name': 'studio'},
          remote: Remote(
            core: core,
            route: 1,
            welcome: {'platform': 'linux', 'features': features},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return core;
}

Future<void> choose(WidgetTester tester, String item) async {
  await tester.tap(find.text(item));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lays the computer out by workspace', (tester) async {
    await open(tester);
    double y(String text) => tester.getTopLeft(find.text(text).first).dy;
    expect(find.text('runner'), findsOneWidget);
    expect(find.text('Ship it'), findsOneWidget);
    expect(find.textContaining('@coder'), findsOneWidget);
    expect(find.textContaining('需要你'), findsOneWidget);
    // The workspace's mission and single-pane tab, then a split tab outside any workspace.
    expect(y('runner') < y('Ship it'), isTrue);
    expect(y('Ship it') < y('Fix the build'), isTrue);
    expect(y('Fix the build') < y('其他'), isTrue);
    expect(y('其他') < y('Pair review'), isTrue);
    expect(find.text('标签页 · 2 个会话'), findsOneWidget);
    expect(find.text('终端'), findsOneWidget, reason: 'an untitled shell');
  });

  testWidgets('starts a chat with a runtime and opens it', (tester) async {
    final core = await open(tester);
    await tester.tap(find.byKey(const Key('new')));
    await tester.pumpAndSettle();
    await choose(tester, '新建聊天');
    // No roles on this computer: the runtime list shows only installed runtimes.
    expect(find.text('Claude Code'), findsOneWidget);
    await tester.tap(find.byKey(const Key('start')));
    await tester.pumpAndSettle();
    final start = core.of('startChat').single;
    expect(start['runtime'], 'claude');
    expect(start['role'], isNull);
    expect(start['project'], isNull);
    expect(start['cols'], startCols);
    expect(core.of('attach').single['session'], 's9');
  });

  testWidgets('starts a mission in a workspace', (tester) async {
    final core = await open(tester);
    await tester.tap(find.byTooltip('工作区操作'));
    await tester.pumpAndSettle();
    await choose(tester, '新建任务');
    expect(find.text('trio'), findsOneWidget);
    expect(
      find.text('runner'),
      findsOneWidget,
      reason: 'the workspace is chosen',
    );
    await tester.enterText(find.byKey(const Key('title')), 'Release 0.2');
    await tester.enterText(find.byKey(const Key('goal')), 'Ship the app');
    await tester.pump();
    await tester.tap(find.byKey(const Key('start')));
    await tester.pumpAndSettle();
    final start = core.of('startMission').single;
    expect(start['crew'], 'c1');
    expect(start['project'], 'p1');
    expect(start['title'], 'Release 0.2');
    expect(start['goal'], 'Ship the app');
    expect(find.text('任务已启动'), findsOneWidget);
  });

  testWidgets('creates a workspace from a folder on the computer', (
    tester,
  ) async {
    final core = await open(tester);
    await tester.tap(find.byKey(const Key('new')));
    await tester.pumpAndSettle();
    await choose(tester, '新建工作区');
    await choose(tester, '文件夹');
    expect(find.text('/home/alice'), findsOneWidget);
    await choose(tester, 'code');
    expect(core.of('folders').last['path'], '/home/alice/code');
    await tester.tap(find.byKey(const Key('chooseFolder')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('projectName')))
          .controller!
          .text,
      'code',
      reason: 'named after the folder',
    );
    await tester.tap(find.byKey(const Key('create')));
    await tester.pumpAndSettle();
    expect(core.of('createProject').single, {
      'type': 'createProject',
      'name': 'code',
      'path': '/home/alice/code',
    });
    expect(find.text('工作区已创建'), findsOneWidget);
  });

  testWidgets('starts a stopped session again and opens it', (tester) async {
    final core = await open(tester);
    await tester.tap(find.text('终端'));
    await tester.pumpAndSettle();
    expect(find.text('会话已停止'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '启动'));
    await tester.pumpAndSettle();
    expect(core.of('resume').single['session'], 's2');
    expect(core.of('attach').single['session'], 's2');
  });

  testWidgets('stops, renames and archives from the menu', (tester) async {
    final core = await open(tester);
    // Past the floating button, which the list leaves room to scroll clear of.
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-s3')));
    await tester.pumpAndSettle();
    await choose(tester, '停止');
    await tester.tap(find.widgetWithText(FilledButton, '停止'));
    await tester.pumpAndSettle();
    expect(core.of('stop').single['session'], 's3');

    await tester.tap(find.byKey(const Key('menu-s3')));
    await tester.pumpAndSettle();
    await choose(tester, '重命名');
    await tester.enterText(find.byKey(const Key('name')), 'Code review');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(core.of('rename').single['target'], {'kind': 'session', 'id': 's3'});
    expect(core.of('rename').single['name'], 'Code review');

    await tester.scrollUntilVisible(find.text('Ship it'), -100);
    await tester.longPress(find.text('Ship it'));
    await tester.pumpAndSettle();
    await choose(tester, '归档');
    await tester.tap(find.widgetWithText(FilledButton, '归档'));
    await tester.pumpAndSettle();
    expect(core.of('archive').single['target'], {
      'kind': 'mission',
      'id': 'm1',
    });
  });

  testWidgets('deleting a busy workspace asks before forcing it', (
    tester,
  ) async {
    final core = await open(tester);
    core.answers['deleteProject'] = (m) => m['force'] == true
        ? {'archivedMissions': [], 'archivedSessions': []}
        : throw CoreException('The project has running chats or missions.');
    await tester.tap(find.byTooltip('工作区操作'));
    await tester.pumpAndSettle();
    await choose(tester, '删除工作区');
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.text('工作区里还有运行中的会话'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '仍然删除'));
    await tester.pumpAndSettle();
    expect(core.of('deleteProject').map((r) => r['force']), [false, true]);
  });

  testWidgets('offers only what the computer serves', (tester) async {
    await open(tester, features: ['overview', 'attach', 'startChat']);
    await tester.tap(find.byKey(const Key('new')));
    await tester.pumpAndSettle();
    final mission = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '新建任务'),
    );
    final chat = tester.widget<ListTile>(find.widgetWithText(ListTile, '新建聊天'));
    expect(mission.enabled, isFalse);
    expect(chat.enabled, isTrue);
  });
}
