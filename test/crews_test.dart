import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:runner_remote/core/core.dart';
import 'package:runner_remote/core/remote.dart';
import 'package:runner_remote/core/store.dart';
import 'package:runner_remote/pages/crews.dart';
import 'package:runner_remote/pages/start.dart';
import 'package:runner_remote/services.dart';

const crewFeatures = [
  'catalog',
  'crew',
  'createCrew',
  'updateCrew',
  'deleteCrew',
  'addSlot',
  'updateSlot',
  'removeSlot',
  'reorderSlots',
  'startMission',
];

/// A computer whose crews change as Runner changes them, recording requests.
class CrewComputer extends Core {
  final requests = <Map<String, Object?>>[];
  final _routes = StreamController<RouteEvent>.broadcast();
  var _next = 10;

  /// Errors to answer a request type with, as the computer would refuse it.
  final refuse = <String, String>{};

  final crews = <Map<String, dynamic>>[
    {
      'id': 'c1',
      'name': 'Duo',
      'conventions': 'Review before committing.',
      'slots': <Map<String, dynamic>>[
        {
          'id': 's1',
          'handle': 'coder',
          'role': 'r1',
          'lead': false,
          'runtime': null,
          'model': null,
          'effort': null,
          'speed': null,
        },
        {
          'id': 's2',
          'handle': 'reviewer',
          'role': 'r2',
          'lead': false,
          'runtime': 'codex',
          'model': 'gpt-6.1',
          'effort': null,
          'speed': null,
        },
      ],
    },
  ];

  List<Map<String, Object?>> of(String type) =>
      requests.where((r) => r['type'] == type).toList();

  Map<String, dynamic> _crew(Object? id) =>
      crews.firstWhere((c) => c['id'] == id);

  List<Map<String, dynamic>> _slots(Object? crew) =>
      (_crew(crew)['slots'] as List).cast<Map<String, dynamic>>();

  Map<String, dynamic> _slot(Object? id) => crews
      .expand((c) => (c['slots'] as List).cast<Map<String, dynamic>>())
      .firstWhere((s) => s['id'] == id);

  Map<String, dynamic> catalog() => {
    'roles': [
      {
        'id': 'r1',
        'name': 'Coder',
        'handle': 'coder',
        'runtime': 'claude',
        'model': null,
        'effort': null,
        'speed': null,
      },
      {
        'id': 'r2',
        'name': 'Reviewer',
        'handle': 'reviewer',
        'runtime': 'claude',
        'model': null,
        'effort': null,
        'speed': null,
      },
    ],
    'runtimes': [
      {
        'name': 'claude',
        'label': 'Claude Code',
        'available': true,
        'models': [
          {'value': 'opus', 'label': 'Opus', 'supportedEfforts': null},
        ],
        'efforts': [
          {'value': 'low', 'label': 'Low', 'supportedEfforts': null},
          {'value': 'high', 'label': 'High', 'supportedEfforts': null},
        ],
        'speeds': <String>[],
      },
      {
        'name': 'codex',
        'label': 'Codex',
        'available': true,
        'models': [
          {
            'value': 'gpt-6.1',
            'label': 'GPT-6.1',
            'supportedEfforts': ['high'],
          },
        ],
        'efforts': [
          {'value': 'low', 'label': 'Low', 'supportedEfforts': null},
          {'value': 'high', 'label': 'High', 'supportedEfforts': null},
        ],
        'speeds': ['standard', 'fast'],
      },
    ],
    'accounts': [],
    'activeAccount': '',
    'crews': [
      for (final c in crews)
        {
          'id': c['id'],
          'name': c['name'],
          'slots': [
            for (final s in (c['slots'] as List).cast<Map<String, dynamic>>())
              {'handle': s['handle'], 'role': s['role'], 'lead': false},
          ],
        },
    ],
    'projects': [],
    'recentFolders': [],
  };

  Object? _answer(Map<String, Object?> m) {
    switch (m['type']) {
      case 'catalog':
        return catalog();
      case 'crew':
        final crew = _crew(m['crew']);
        return {
          ...crew,
          'slots': [
            for (final s in _slots(m['crew'])) {...s},
          ],
        };
      case 'createCrew':
        final id = 'c${_next++}';
        crews.add({
          'id': id,
          'name': m['name'],
          'conventions': m['conventions'],
          'slots': <Map<String, dynamic>>[],
        });
        return {'crew': id};
      case 'updateCrew':
        _crew(m['crew'])
          ..['name'] = m['name']
          ..['conventions'] = m['conventions'];
      case 'deleteCrew':
        crews.removeWhere((c) => c['id'] == m['crew']);
      case 'addSlot':
        final id = 's${_next++}';
        _slots(m['crew']).add({
          'id': id,
          'handle': m['handle'],
          'role': m['role'],
          'lead': false,
          'runtime': m['runtime'],
          'model': m['model'],
          'effort': null,
          'speed': null,
        });
        return {'slot': id};
      case 'updateSlot':
        _slot(m['slot']).addAll({
          for (final key in ['handle', 'runtime', 'model', 'effort', 'speed'])
            key: m[key],
        });
      case 'removeSlot':
        for (final c in crews) {
          (c['slots'] as List).removeWhere(
            (s) => (s as Map)['id'] == m['slot'],
          );
        }
      case 'reorderSlots':
        final slots = _slots(m['crew']);
        final order = (m['order'] as List).cast<String>();
        slots.sort(
          (a, b) => order.indexOf(a['id']).compareTo(order.indexOf(b['id'])),
        );
      case 'startMission':
        return {'mission': 'm9'};
    }
    return null;
  }

  @override
  Stream<RouteEvent> get routeEvents => _routes.stream;

  @override
  Future<dynamic> call(String op, Map<String, Object?> args) async {
    if (op != 'request') return null;
    final message = args['message'] as Map<String, Object?>;
    requests.add(message);
    final refused = refuse[message['type']];
    if (refused != null) throw CoreException(refused);
    return _answer(message);
  }
}

/// The crews page over [core], opened from a page that keeps what it pops with.
Future<List<Started?>> crewsPage(
  WidgetTester tester,
  CrewComputer core, {
  List<String> features = crewFeatures,
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final remote = Remote(
    core: core,
    route: 1,
    welcome: {'platform': 'linux', 'features': features},
    open: () async => throw CoreException('no reconnects here'),
  );
  addTearDown(remote.dispose);
  final popped = <Started?>[];
  await tester.pumpWidget(
    Services(
      core: core,
      store: Store(),
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => popped.add(
                  await Navigator.of(context).push<Started>(
                    MaterialPageRoute(
                      builder: (_) => CrewsPage(remote: remote),
                    ),
                  ),
                ),
                child: const Text('open crews'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open crews'));
  await tester.pumpAndSettle();
  return popped;
}

Future<void> openDuo(WidgetTester tester) async {
  await tester.tap(find.text('Duo'));
  await tester.pumpAndSettle();
}

void main() {
  test('handles follow Runner\'s rule and suggestions', () {
    expect(slotHandleError('coder', ['reviewer']), isNull);
    expect(slotHandleError('code_2-x', []), isNull);
    expect(slotHandleError('coder', ['coder']), contains('已在这个团队中'));
    for (final bad in ['Coder', '-coder', 'co der', 'a' * 33, '编码']) {
      expect(slotHandleError(bad, []), isNotNull, reason: bad);
    }
    expect(slotHandleError('', []), isNotNull);
    expect(suggestSlotHandle('coder', ['reviewer']), 'coder');
    expect(suggestSlotHandle('coder', ['coder', 'coder-2']), 'coder-3');
  });

  testWidgets('lists the crews and shows one with its members', (tester) async {
    final core = CrewComputer();
    await crewsPage(tester, core);
    expect(find.text('Duo'), findsOneWidget);
    expect(find.text('2 名成员 · @coder @reviewer'), findsOneWidget);

    await openDuo(tester);
    expect(core.of('crew').single['crew'], 'c1');
    expect(find.text('Review before committing.'), findsOneWidget);
    expect(find.text('@coder'), findsOneWidget);
    expect(find.text('Coder · 跟随角色设置'), findsOneWidget);
    expect(find.text('Reviewer · Codex · gpt-6.1'), findsOneWidget);
  });

  testWidgets('creates a crew and opens it', (tester) async {
    final core = CrewComputer();
    await crewsPage(tester, core);
    await tester.tap(find.byKey(const Key('newCrew')));
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('crewSave'));
    expect(
      tester.widget<FilledButton>(save).onPressed,
      isNull,
      reason: 'a name is needed',
    );
    await tester.enterText(find.byKey(const Key('crewName')), '  Trio ');
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(core.of('createCrew').single, {
      'type': 'createCrew',
      'name': 'Trio',
      'conventions': null,
    });
    // Opened at once, with nothing in it yet.
    expect(find.widgetWithText(AppBar, 'Trio'), findsOneWidget);
    expect(find.text('还没有成员'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Trio'), findsOneWidget);
  });

  testWidgets('edits the crew and deletes it', (tester) async {
    final core = CrewComputer();
    await crewsPage(tester, core);
    await openDuo(tester);
    await tester.tap(find.byKey(const Key('crewEdit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('crewName')), 'Pair');
    await tester.enterText(find.byKey(const Key('crewConventions')), '');
    await tester.tap(find.byKey(const Key('crewSave')));
    await tester.pumpAndSettle();
    expect(core.of('updateCrew').single, {
      'type': 'updateCrew',
      'crew': 'c1',
      'name': 'Pair',
      'conventions': null,
    });
    expect(find.widgetWithText(AppBar, 'Pair'), findsOneWidget);
    expect(find.text('未设置'), findsOneWidget);

    await tester.tap(find.byKey(const Key('crewMenu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除团队'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('crewDeleteConfirm')));
    await tester.pumpAndSettle();
    expect(core.of('deleteCrew').single['crew'], 'c1');
    // Back on the list, which no longer has it.
    expect(find.byKey(const Key('newCrew')), findsOneWidget);
    expect(find.text('Pair'), findsNothing);
    expect(find.text('这台电脑上还没有团队'), findsOneWidget);
  });

  testWidgets('adds a member under a free handle', (tester) async {
    final core = CrewComputer();
    await crewsPage(tester, core);
    await openDuo(tester);
    await tester.tap(find.byKey(const Key('addSlot')));
    await tester.pumpAndSettle();
    // Coder is taken, so the role's handle comes with a number.
    final handle = find.byKey(const Key('slotHandle'));
    expect(tester.widget<TextField>(handle).controller!.text, 'coder-2');
    final save = find.byKey(const Key('slotSave'));

    await tester.enterText(handle, 'Bad Name');
    await tester.pump();
    expect(find.textContaining('只能用小写字母'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.enterText(handle, 'reviewer');
    await tester.pump();
    expect(find.text('@reviewer 已在这个团队中'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.enterText(handle, 'tester');
    await tester.pump();
    await tester.tap(find.byKey(const Key('slotRuntime')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Codex').last);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(core.of('addSlot').single, {
      'type': 'addSlot',
      'crew': 'c1',
      'role': 'r1',
      'handle': 'tester',
      'runtime': 'codex',
      'model': null,
    });
    expect(find.text('@tester'), findsOneWidget);
    expect(find.text('Coder · Codex'), findsOneWidget);
  });

  testWidgets('edits a member, keeping what it did not change', (tester) async {
    final core = CrewComputer();
    await crewsPage(tester, core);
    await openDuo(tester);
    await tester.tap(find.text('@reviewer'));
    await tester.pumpAndSettle();
    // Codex's GPT-6.1 takes only High effort, and Codex has speeds.
    await tester.tap(find.byKey(const Key('slotEffort.codex.gpt-6.1')));
    await tester.pumpAndSettle();
    expect(find.text('Low'), findsNothing);
    await tester.tap(find.text('High').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('slotSpeed.codex')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('快速').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('slotSave')));
    await tester.pumpAndSettle();
    expect(core.of('updateSlot').single, {
      'type': 'updateSlot',
      'slot': 's2',
      'handle': 'reviewer',
      'runtime': 'codex',
      'model': 'gpt-6.1',
      'effort': 'high',
      'speed': 'fast',
    });
    expect(
      find.text('Reviewer · Codex · gpt-6.1 · 推理 high · 快速'),
      findsOneWidget,
    );

    // Back to the role's runtime drops what only Codex had.
    await tester.tap(find.text('@reviewer'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('slotRuntime')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跟随角色（Claude Code）').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('slotSave')));
    await tester.pumpAndSettle();
    expect(core.of('updateSlot').last, {
      'type': 'updateSlot',
      'slot': 's2',
      'handle': 'reviewer',
      'runtime': null,
      'model': null,
      'effort': 'high',
      'speed': null,
    });
  });

  testWidgets('removes and reorders members', (tester) async {
    final core = CrewComputer();
    await crewsPage(tester, core);
    await openDuo(tester);

    // Long-press @coder and drag it below @reviewer.
    final from = tester.getCenter(find.text('@coder'));
    final gesture = await tester.startGesture(from);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(core.of('reorderSlots').single, {
      'type': 'reorderSlots',
      'crew': 'c1',
      'order': ['s2', 's1'],
    });
    expect(
      tester.getCenter(find.text('@reviewer')).dy,
      lessThan(tester.getCenter(find.text('@coder')).dy),
    );

    await tester.tap(find.byKey(const Key('slotRemove.s1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('slotRemoveConfirm')));
    await tester.pumpAndSettle();
    expect(core.of('removeSlot').single['slot'], 's1');
    expect(find.text('@coder'), findsNothing);
    expect(find.text('@reviewer'), findsOneWidget);
  });

  testWidgets('a refused change is reported and the crew shown as it is', (
    tester,
  ) async {
    final core = CrewComputer()
      ..refuse['removeSlot'] = 'That slot is used by a running mission.';
    await crewsPage(tester, core);
    await openDuo(tester);
    await tester.tap(find.byKey(const Key('slotRemove.s1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('slotRemoveConfirm')));
    await tester.pumpAndSettle();
    expect(
      find.text('That slot is used by a running mission.'),
      findsOneWidget,
    );
    expect(find.text('@coder'), findsOneWidget);
  });

  testWidgets('starts a mission with the crew', (tester) async {
    final core = CrewComputer();
    final popped = await crewsPage(tester, core);
    await openDuo(tester);
    await tester.tap(find.byKey(const Key('crewStartMission')));
    await tester.pumpAndSettle();
    expect(find.text('Duo'), findsOneWidget, reason: 'chosen already');
    await tester.enterText(find.byKey(const Key('title')), 'Ship it');
    await tester.pump();
    await tester.tap(find.byKey(const Key('start')));
    await tester.pumpAndSettle();
    expect(core.of('startMission').single['crew'], 'c1');
    expect(core.of('startMission').single['title'], 'Ship it');
    // Every crew page closed, handing the mission back to the computer page.
    expect(popped.single?.mission, 'm9');
    expect(find.text('open crews'), findsOneWidget);
  });

  testWidgets('a computer that cannot change crews only shows them', (
    tester,
  ) async {
    final core = CrewComputer();
    await crewsPage(tester, core, features: const ['catalog', 'crew']);
    expect(find.byKey(const Key('newCrew')), findsNothing);
    await openDuo(tester);
    expect(find.text('@coder'), findsOneWidget);
    for (final key in [
      'crewEdit',
      'crewMenu',
      'addSlot',
      'slotRemove.s1',
      'crewStartMission',
    ]) {
      expect(find.byKey(Key(key)), findsNothing, reason: key);
    }
    await tester.tap(find.text('@coder'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('slotSave')), findsNothing);
    expect(core.requests.map((r) => r['type']).toSet(), {'catalog', 'crew'});
  });
}
