import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:runner_remote/core/core.dart';
import 'package:runner_remote/core/remote.dart';
import 'package:runner_remote/core/store.dart';
import 'package:runner_remote/pages/mission.dart';
import 'package:runner_remote/services.dart';

const chatFeatures = ['feed', 'follow', 'unfollow', 'post', 'answer'];

/// As the host sends it: decoded JSON, so its maps take any value.
Map<String, dynamic> missionOverview({String state = 'running'}) =>
    jsonDecode(jsonEncode(_overview(state))) as Map<String, dynamic>;

Map<String, dynamic> _overview(String state) => {
  'projects': [],
  'tabs': [],
  'missions': [
    {
      'id': 'm1',
      'project': null,
      'title': 'Ship it',
      'crew': 'Duo',
      'state': state,
      'pinned': false,
      'members': [
        {'handle': 'coder', 'session': 's4', 'lead': false},
        {'handle': 'reviewer', 'session': 's5', 'lead': false},
      ],
      'asks': [],
      'shells': [],
    },
  ],
  'sessions': {
    's4': {
      'kind': 'agent',
      'title': 'Coder',
      'status': 'needsYou',
      'unread': false,
    },
    's5': {
      'kind': 'agent',
      'title': 'Review',
      'status': 'working',
      'unread': false,
    },
  },
};

Map<String, dynamic> entry(
  String id,
  String from,
  Map<String, dynamic> content, {
  List<String> to = const [],
}) => {
  'id': id,
  'ts': '2026-11-24T04:0${id.substring(1)}:00Z',
  'from': from,
  'to': to,
  ...content,
};

/// The latest page, newest first as Runner sends it.
List<Map<String, dynamic>> latestPage() => [
  entry('e5', 'coder', {
    'kind': 'ask',
    'question': 'q1',
    'prompt': 'Run the full suite?',
    'choices': ['Yes', 'No'],
  }),
  entry('e4', 'human', {
    'kind': 'signal',
    'signal': 'human_said',
    'payload': {
      'text': 'Please review the fixtures.',
      'target': ['reviewer'],
      'delivery': 'inbox',
    },
  }),
  entry('e3', 'system', {
    'kind': 'signal',
    'signal': 'runner_status',
    'payload': {'state': 'busy'},
  }),
  entry('e2', 'coder', {'kind': 'message', 'text': 'Ready for review.'}),
  entry('e1', 'human', {
    'kind': 'signal',
    'signal': 'mission_goal',
    'payload': {'text': 'Ship the release.'},
  }),
];

/// A computer serving one mission's feed, recording requests.
class ChatComputer extends Core {
  final requests = <Map<String, Object?>>[];
  final _routes = StreamController<RouteEvent>.broadcast();

  List<Map<String, Object?>> of(String type) =>
      requests.where((r) => r['type'] == type).toList();

  void push(Map<String, dynamic> message) =>
      _routes.add(RouteEvent(1, message));

  void append(List<Map<String, dynamic>> entries) =>
      push({'type': 'feedAppended', 'mission': 'm1', 'entries': entries});

  @override
  Stream<RouteEvent> get routeEvents => _routes.stream;

  @override
  Future<dynamic> call(String op, Map<String, Object?> args) async {
    if (op != 'request') return null;
    final message = args['message'] as Map<String, Object?>;
    requests.add(message);
    switch (message['type']) {
      case 'feed':
        return message['before'] == null
            ? {'entries': latestPage(), 'before': 'older'}
            : {
                'entries': [
                  entry('e0', 'reviewer', {
                    'kind': 'message',
                    'text': 'Earlier note.',
                  }),
                ],
                'before': null,
              };
    }
    return null;
  }
}

class Opened {
  final sessions = <(String, String)>[];
}

Future<(ChatComputer, Opened)> missionPage(
  WidgetTester tester, {
  List<String> features = chatFeatures,
  String state = 'running',
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final core = ChatComputer();
  final opened = Opened();
  final remote = Remote(
    core: core,
    route: 1,
    welcome: {'platform': 'linux', 'features': features},
    open: () async => throw CoreException('no reconnects here'),
  );
  addTearDown(remote.dispose);
  await tester.pumpWidget(
    Services(
      core: core,
      store: Store(),
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => MissionPage(
                    remote: remote,
                    mission: 'm1',
                    overview: missionOverview(state: state),
                    openSession: (session, title) async =>
                        opened.sessions.add((session, title)),
                  ),
                ),
              ),
              child: const Text('open mission'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open mission'));
  await tester.pumpAndSettle();
  return (core, opened);
}

void main() {
  test('recipients read as Runner writes them', () {
    expect(recipients('coder'), ['coder']);
    expect(recipients(['coder', 'reviewer']), ['coder', 'reviewer']);
    expect(recipients(null), isNull);
  });

  testWidgets('follows the mission and shows its feed as a chat', (
    tester,
  ) async {
    final (core, _) = await missionPage(tester);
    // Followed first, so nothing posted while the page loads is missed.
    expect(core.requests.map((r) => r['type']).take(2), ['follow', 'feed']);
    expect(core.of('feed').single, {
      'type': 'feed',
      'mission': 'm1',
      'before': null,
      'limit': 50,
    });
    expect(find.text('Ship it'), findsOneWidget);
    expect(find.text('Duo · 运行中 · 2 名成员'), findsOneWidget);
    expect(find.text('任务目标'), findsOneWidget);
    expect(find.text('Ship the release.'), findsOneWidget);
    expect(find.text('Ready for review.'), findsOneWidget);
    expect(find.textContaining('@coder  → 所有人'), findsOneWidget);
    expect(find.text('Please review the fixtures.'), findsOneWidget);
    expect(find.textContaining('你  → @reviewer'), findsOneWidget);
    expect(find.text('Run the full suite?'), findsOneWidget);
    expect(
      find.textContaining('runner_status'),
      findsNothing,
      reason: 'bookkeeping',
    );
    // Oldest at the top.
    expect(
      tester.getTopLeft(find.text('Ship the release.')).dy,
      lessThan(tester.getTopLeft(find.text('Run the full suite?')).dy),
    );
  });

  testWidgets('loads older entries above', (tester) async {
    final (core, _) = await missionPage(tester);
    await tester.scrollUntilVisible(
      find.byKey(const Key('older')),
      -300,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('feed')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.byKey(const Key('older')));
    await tester.pumpAndSettle();
    expect(core.of('feed').last['before'], 'older');
    expect(find.text('Earlier note.'), findsOneWidget);
    expect(find.byKey(const Key('older')), findsNothing, reason: 'the start');
  });

  testWidgets('new entries arrive live, each once', (tester) async {
    final (core, _) = await missionPage(tester);
    final note = entry(
      'e6',
      'reviewer',
      {'kind': 'message', 'text': 'Looks good.'},
      to: ['coder'],
    );
    core.append([note]);
    core.append([note]);
    await tester.pumpAndSettle();
    expect(find.text('Looks good.'), findsOneWidget);
    expect(find.textContaining('@reviewer  → @coder'), findsOneWidget);
    // Another mission's entries are not this one's.
    core.push({
      'type': 'feedAppended',
      'mission': 'm2',
      'entries': [
        entry('e7', 'x', {'kind': 'message', 'text': 'Elsewhere.'}),
      ],
    });
    await tester.pumpAndSettle();
    expect(find.text('Elsewhere.'), findsNothing);
  });

  testWidgets('answers a question with a choice', (tester) async {
    final (core, _) = await missionPage(tester);
    await tester.tap(find.byKey(const Key('choice.Yes')));
    await tester.pumpAndSettle();
    expect(core.of('answer').single, {
      'type': 'answer',
      'mission': 'm1',
      'question': 'q1',
      'text': 'Yes',
    });
    // The host records the answer, and the question shows it.
    core.append([
      entry('e6', 'human', {'kind': 'answer', 'question': 'q1', 'text': 'Yes'}),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('已回答：Yes'), findsOneWidget);
    expect(find.byKey(const Key('choice.Yes')), findsNothing);
  });

  testWidgets('answers in its own words', (tester) async {
    final (core, _) = await missionPage(tester);
    await tester.tap(find.byKey(const Key('reply')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('answerText')),
      'Only the fast tests',
    );
    await tester.tap(find.byKey(const Key('answerSend')));
    await tester.pumpAndSettle();
    expect(core.of('answer').single['text'], 'Only the fast tests');
  });

  testWidgets('posts to everyone or to chosen members', (tester) async {
    final (core, _) = await missionPage(tester);
    final send = find.byKey(const Key('send'));
    expect(
      tester.widget<IconButton>(send).onPressed,
      isNull,
      reason: 'nothing typed',
    );
    expect(find.text('发给：所有人'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('draft')), '@coder Status?');
    await tester.pump();
    await tester.tap(send);
    await tester.pumpAndSettle();
    // Runner routes a leading @mention itself.
    expect(core.of('post').single, {
      'type': 'post',
      'mission': 'm1',
      'to': <String>[],
      'text': '@coder Status?',
    });
    expect(
      tester.widget<TextField>(find.byKey(const Key('draft'))).controller!.text,
      isEmpty,
    );

    await tester.tap(find.byKey(const Key('recipients')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('to.reviewer')));
    await tester.tap(find.byKey(const Key('recipientsDone')));
    await tester.pumpAndSettle();
    expect(find.text('发给：@reviewer'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('draft')), 'Please check.');
    await tester.pump();
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(core.of('post').last['to'], ['reviewer']);
  });

  testWidgets('expands the members, each opening its own conversation', (
    tester,
  ) async {
    final (core, opened) = await missionPage(tester);
    expect(find.byKey(const Key('membersPanel')), findsNothing);
    await tester.tap(find.byKey(const Key('members')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('membersPanel')), findsOneWidget);
    expect(find.text('@coder'), findsOneWidget);
    expect(find.text('需要你 · Coder'), findsOneWidget);
    expect(find.text('工作中 · Review'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memberChat.coder')));
    await tester.pumpAndSettle();
    expect(opened.sessions, [('s4', '@coder')]);

    // Status pushes keep the members current.
    core.push({
      'type': 'status',
      'session': 's5',
      'status': 'idle',
      'reason': null,
      'unread': false,
    });
    await tester.pumpAndSettle();
    expect(find.text('空闲 · Review'), findsOneWidget);

    await tester.tap(find.byKey(const Key('memberMention.reviewer')));
    await tester.pumpAndSettle();
    expect(find.text('发给：@reviewer'), findsOneWidget);

    await tester.tap(find.byKey(const Key('members')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('membersPanel')), findsNothing);
  });

  testWidgets('a stopped mission still takes messages', (tester) async {
    final (core, _) = await missionPage(tester, state: 'stopped');
    expect(find.text('Duo · 已停止 · 2 名成员'), findsOneWidget);
    expect(find.text('任务已停止，消息会先记在任务里'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('draft')), 'For later.');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send')));
    await tester.pumpAndSettle();
    expect(core.of('post').single['text'], 'For later.');
    // Resumed elsewhere: the overview push shows it running.
    core.push({'type': 'overview', ...missionOverview()});
    await tester.pumpAndSettle();
    expect(find.text('Duo · 运行中 · 2 名成员'), findsOneWidget);
  });

  testWidgets('a computer without posts shows the chat only', (tester) async {
    final (core, _) = await missionPage(
      tester,
      features: const ['feed', 'follow', 'unfollow'],
    );
    expect(find.text('Ready for review.'), findsOneWidget);
    expect(find.text('这台电脑不支持发消息'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const Key('draft'))).enabled,
      isFalse,
    );
    expect(find.byKey(const Key('choice.Yes')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('choice.Yes')))
          .onPressed,
      isNull,
      reason: 'answering is its own feature',
    );
    expect(core.of('post'), isEmpty);
  });

  testWidgets('leaving unfollows', (tester) async {
    final (core, _) = await missionPage(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(core.of('unfollow').single['mission'], 'm1');
  });
}
