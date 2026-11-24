import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/core.dart';
import '../core/remote.dart';
import '../core/store.dart';
import '../services.dart';
import 'crews.dart';
import 'start.dart';
import 'terminal.dart';

/// One connected computer: its workspaces with their missions and chats, and
/// the actions to start, stop, rename and archive them.
class ComputerPage extends StatefulWidget {
  const ComputerPage({
    super.key,
    required this.account,
    required this.computer,
    required this.remote,
    this.session,
  });

  final Account account;
  final Map<String, dynamic> computer;
  final Remote remote;

  /// A session to open once the overview arrives, as from a notification.
  final String? session;

  @override
  State<ComputerPage> createState() => _ComputerPageState();
}

class _ComputerPageState extends State<ComputerPage> {
  StreamSubscription<RouteEvent>? _events;
  Map<String, dynamic>? _overview;
  var _wasConnected = true;

  Remote get _remote => widget.remote;

  /// [ComputerPage.session] until it has been opened.
  late String? _pendingSession = widget.session;

  @override
  void initState() {
    super.initState();
    _events = _remote.pushes.listen(_onEvent);
    _remote.addListener(_onState);
    _refresh();
  }

  @override
  void dispose() {
    _events?.cancel();
    _remote.removeListener(_onState);
    _remote.dispose();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    // A new route starts with no overview push; ask for it.
    if (_remote.connected && !_wasConnected) _refresh();
    _wasConnected = _remote.connected;
  }

  Future<void> _refresh() async {
    try {
      final overview = await _remote.request('overview');
      if (!mounted) return;
      setState(() => _overview = overview as Map<String, dynamic>);
      _openPending();
    } catch (e) {
      if (mounted && _remote.connected) showError(context, e);
    }
  }

  void _openPending() {
    final id = _pendingSession;
    if (id == null) return;
    _pendingSession = null;
    final sessions = _overview?['sessions'] as Map<String, dynamic>?;
    final session = sessions?[id] as Map<String, dynamic>?;
    if (session == null) {
      showMessage(context, '这个会话已不在电脑上');
      return;
    }
    unawaited(_openSession(id, session));
  }

  void _onEvent(RouteEvent event) {
    final message = event.message!;
    switch (event.type) {
      case 'overview':
        setState(() => _overview = message);
      case 'status':
        final sessions = _overview?['sessions'] as Map<String, dynamic>?;
        final session = sessions?[message['session']] as Map<String, dynamic>?;
        if (session == null) return;
        setState(() {
          for (final key in const ['status', 'reason', 'unread']) {
            session[key] = message[key];
          }
        });
    }
  }

  /// Runs an action and reports its failure; the host pushes the new overview.
  Future<T?> _act<T>(Future<T> Function() action, {String? done}) async {
    try {
      final result = await action();
      if (mounted && done != null) showMessage(context, done);
      unawaited(_refresh());
      return result;
    } catch (e) {
      if (mounted) showError(context, e);
      return null;
    }
  }

  Future<void> _openTerminal(String session, String title) async {
    final sessions = _overview?['sessions'] as Map<String, dynamic>?;
    final runtime = (sessions?[session] as Map?)?['runtime'] as String?;
    if ((sessions?[session] as Map?)?['unread'] == true &&
        _remote.has('markViewed')) {
      unawaited(
        _remote.request('markViewed', {'session': session}).catchError((_) {}),
      );
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalPage(
          remote: _remote,
          session: session,
          title: title,
          runtime: runtime,
          account: widget.account,
          computer: widget.computer['id'] as String?,
        ),
      ),
    );
  }

  Future<void> _start(StartKind kind, {String? project}) async {
    final started = await Navigator.of(context).push<Started>(
      MaterialPageRoute(
        builder: (_) =>
            StartPage(remote: _remote, kind: kind, project: project),
      ),
    );
    if (started == null || !mounted) return;
    if (started.session != null) {
      // The new session's runtime comes with the overview.
      await _refresh();
      if (!mounted) return;
      await _openTerminal(
        started.session!,
        kind == StartKind.shell ? '终端' : '新聊天',
      );
    } else {
      unawaited(_refresh());
      showMessage(context, '任务已启动');
    }
  }

  /// The computer's crews; a mission started from one shows here like any other.
  Future<void> _crews() async {
    final started = await Navigator.of(context).push<Started>(
      MaterialPageRoute(builder: (_) => CrewsPage(remote: _remote)),
    );
    if (started == null || !mounted) return;
    unawaited(_refresh());
    showMessage(context, '任务已启动');
  }

  Future<void> _newProject() async {
    final project = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => NewProjectPage(remote: _remote)),
    );
    if (project != null && mounted) {
      showMessage(context, '工作区已创建');
      unawaited(_refresh());
    }
  }

  void _showNewMenu({String? project}) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) {
        Widget item(
          IconData icon,
          String label,
          String feature,
          VoidCallback onTap,
        ) => ListTile(
          leading: Icon(icon),
          title: Text(label),
          enabled: _remote.has(feature),
          onTap: () {
            Navigator.pop(sheet);
            onTap();
          },
        );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              item(
                Icons.chat_outlined,
                '新建聊天',
                'startChat',
                () => _start(StartKind.chat, project: project),
              ),
              item(
                Icons.terminal,
                '新建终端',
                'startShell',
                () => _start(StartKind.shell, project: project),
              ),
              item(
                Icons.groups_outlined,
                '新建任务',
                'startMission',
                () => _start(StartKind.mission, project: project),
              ),
              if (project == null)
                item(
                  Icons.create_new_folder_outlined,
                  '新建工作区',
                  'createProject',
                  _newProject,
                ),
            ],
          ),
        );
      },
    );
  }

  Future<String?> _askName(String title, String current) {
    final name = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: TextField(
          key: const Key('name'),
          controller: name,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(dialog, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, name.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _rename(String kind, String id, String current) async {
    final name = await _askName('重命名', current);
    if (name == null || name.isEmpty || name == current) return;
    await _act(
      () => _remote.request('rename', {
        'target': {'kind': kind, 'id': id},
        'name': name,
      }),
    );
  }

  Future<void> _archive(String kind, String id, String what) async {
    if (!await _confirm('归档$what', '归档后它会从列表中移除，正在运行的会话会被停止。', '归档')) return;
    await _act(
      () => _remote.request('archive', {
        'target': {'kind': kind, 'id': id},
      }),
    );
  }

  /// Starts a stopped session again and opens it.
  Future<void> _resume(String id, String title) async {
    final result = await _act(
      () => _remote.request('resume', {
        'session': id,
        'cols': startCols,
        'rows': startRows,
      }),
    );
    if (result is Map && mounted) {
      await _openTerminal(result['session'] as String? ?? id, title);
    }
  }

  Future<void> _openSession(String id, Map<String, dynamic> session) async {
    final title = _sessionTitle(session);
    if (_isStopped(session) && _remote.has('resume')) {
      if (await _confirm('会话已停止', '要在电脑上重新启动「$title」吗？', '启动')) {
        await _resume(id, title);
      }
      return;
    }
    await _openTerminal(id, title);
  }

  void _sessionMenu(String id, Map<String, dynamic> session) {
    final title = _sessionTitle(session);
    final stopped = _isStopped(session);
    _menu(title, [
      ('打开终端', Icons.terminal, 'attach', () => _openTerminal(id, title)),
      if (stopped) ('启动', Icons.play_arrow, 'resume', () => _resume(id, title)),
      if (!stopped)
        (
          '重启',
          Icons.restart_alt,
          'restart',
          () async {
            final result = await _act(
              () => _remote.request('restart', {
                'session': id,
                'cols': startCols,
                'rows': startRows,
              }),
            );
            if (result is Map && mounted) {
              await _openTerminal(result['session'] as String? ?? id, title);
            }
          },
        ),
      if (!stopped)
        (
          '停止',
          Icons.stop,
          'stop',
          () async {
            if (await _confirm('停止会话', '停止「$title」？之后可以再启动。', '停止')) {
              await _act(() => _remote.request('stop', {'session': id}));
            }
          },
        ),
      ('重命名', Icons.edit, 'rename', () => _rename('session', id, title)),
      (
        '归档',
        Icons.archive_outlined,
        'archive',
        () => _archive('session', id, '会话'),
      ),
    ]);
  }

  void _missionMenu(Map<String, dynamic> mission) {
    final id = mission['id'] as String;
    final title = mission['title'] as String? ?? '';
    final running = mission['state'] == 'running';
    _menu(title, [
      if (running)
        (
          '停止任务',
          Icons.stop,
          'stopMission',
          () async {
            if (await _confirm('停止任务', '停止「$title」的所有成员？之后可以恢复。', '停止')) {
              await _act(() => _remote.request('stopMission', {'mission': id}));
            }
          },
        )
      else
        (
          '恢复任务',
          Icons.play_arrow,
          'resumeMission',
          () => _act(
            () => _remote.request('resumeMission', {
              'mission': id,
              'cols': startCols,
              'rows': startRows,
            }),
            done: '任务已恢复',
          ),
        ),
      ('重命名', Icons.edit, 'rename', () => _rename('mission', id, title)),
      (
        '归档',
        Icons.archive_outlined,
        'archive',
        () => _archive('mission', id, '任务'),
      ),
    ]);
  }

  void _tabMenu(Map<String, dynamic> tab) {
    final id = tab['id'] as String;
    final name = tab['name'] as String? ?? '';
    _menu(name, [
      ('重命名', Icons.edit, 'rename', () => _rename('tab', id, name)),
      (
        '归档',
        Icons.archive_outlined,
        'archive',
        () => _archive('tab', id, '标签页'),
      ),
    ]);
  }

  void _projectMenu(Map<String, dynamic> project) {
    final id = project['id'] as String;
    final name = project['name'] as String? ?? '';
    _menu(name, [
      (
        '新建聊天',
        Icons.chat_outlined,
        'startChat',
        () => _start(StartKind.chat, project: id),
      ),
      (
        '新建终端',
        Icons.terminal,
        'startShell',
        () => _start(StartKind.shell, project: id),
      ),
      (
        '新建任务',
        Icons.groups_outlined,
        'startMission',
        () => _start(StartKind.mission, project: id),
      ),
      ('重命名', Icons.edit, 'rename', () => _rename('project', id, name)),
      (
        '删除工作区',
        Icons.delete_outline,
        'deleteProject',
        () => _deleteProject(id, name),
      ),
    ]);
  }

  Future<void> _deleteProject(String id, String name) async {
    if (!await _confirm('删除工作区', '删除「$name」？其中的聊天和任务会被归档，电脑上的文件不受影响。', '删除')) {
      return;
    }
    try {
      await _remote.request('deleteProject', {'project': id, 'force': false});
      unawaited(_refresh());
    } on CoreException catch (e) {
      if (!mounted) return;
      if (!e.message.contains('running')) {
        showError(context, e);
        return;
      }
      if (await _confirm(
        '工作区里还有运行中的会话',
        '仍然删除「$name」？运行中的聊天和任务会被停止并归档。',
        '仍然删除',
      )) {
        await _act(
          () =>
              _remote.request('deleteProject', {'project': id, 'force': true}),
        );
      }
    }
  }

  void _menu(
    String title,
    List<(String, IconData, String, FutureOr<void> Function())> items,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final (label, icon, feature, action) in items)
              if (_remote.has(feature))
                ListTile(
                  leading: Icon(icon),
                  title: Text(label),
                  onTap: () {
                    Navigator.pop(sheet);
                    action();
                  },
                ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final overview = _overview;
    final live = _remote.connected;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.computer['name'] as String? ?? '电脑'),
        actions: [
          if (_remote.has('catalog'))
            IconButton(
              key: const Key('crews'),
              tooltip: '团队',
              icon: const Icon(Icons.groups_outlined),
              onPressed: live ? _crews : null,
            ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: live ? _refresh : null,
          ),
        ],
      ),
      floatingActionButton: live && overview != null
          ? FloatingActionButton.extended(
              key: const Key('new'),
              onPressed: _showNewMenu,
              icon: const Icon(Icons.add),
              label: const Text('新建'),
            )
          : null,
      body: Column(
        children: [
          ReconnectBanner(remote: _remote),
          Expanded(
            child: overview == null
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: _Workspaces(
                      overview: overview,
                      live: live,
                      onSession: _openSession,
                      onSessionMenu: _sessionMenu,
                      onMissionMenu: _missionMenu,
                      onTabMenu: _tabMenu,
                      onProjectMenu: _projectMenu,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

bool _isStopped(Map<String, dynamic> session) =>
    session['status'] == 'stopped' || session['status'] == 'error';

String _sessionTitle(Map<String, dynamic> session) {
  final title = session['title'] as String? ?? '';
  if (title.isNotEmpty) return title;
  return session['kind'] == 'shell' ? '终端' : '未命名';
}

/// The sessions a tab's pane tree holds, in order.
List<String> paneSessions(Object? pane) {
  if (pane is! Map) return const [];
  if (pane.containsKey('split')) {
    return [...paneSessions(pane['a']), ...paneSessions(pane['b'])];
  }
  final session = pane['session'];
  return session is String ? [session] : const [];
}

/// The overview laid out by workspace, as the desktop's sidebar does: each
/// workspace's missions and tabs, then those outside any workspace.
class _Workspaces extends StatelessWidget {
  const _Workspaces({
    required this.overview,
    required this.live,
    required this.onSession,
    required this.onSessionMenu,
    required this.onMissionMenu,
    required this.onTabMenu,
    required this.onProjectMenu,
  });

  final Map<String, dynamic> overview;
  final bool live;
  final void Function(String id, Map<String, dynamic> session) onSession;
  final void Function(String id, Map<String, dynamic> session) onSessionMenu;
  final void Function(Map<String, dynamic> mission) onMissionMenu;
  final void Function(Map<String, dynamic> tab) onTabMenu;
  final void Function(Map<String, dynamic> project) onProjectMenu;

  @override
  Widget build(BuildContext context) {
    List<Map<String, dynamic>> list(String key) =>
        ((overview[key] as List?) ?? const []).cast<Map<String, dynamic>>();
    final sessions = ((overview['sessions'] as Map?) ?? const {})
        .cast<String, Map<String, dynamic>>();
    final projects = list('projects');
    final missions = list('missions');
    final tabs = list('tabs');
    final placed = <String>{};
    final children = <Widget>[];

    Widget session(String id, {String? label, double indent = 0}) {
      placed.add(id);
      return _SessionTile(
        id: id,
        session: sessions[id]!,
        label: label,
        indent: indent,
        onTap: live ? () => onSession(id, sessions[id]!) : null,
        onMenu: live ? () => onSessionMenu(id, sessions[id]!) : null,
      );
    }

    void items(String? project) {
      for (final mission in missions.where((m) => m['project'] == project)) {
        final members = ((mission['members'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .where((m) => sessions.containsKey(m['session']));
        children.add(
          _GroupTile(
            icon: Icons.groups_outlined,
            title: mission['title'] as String? ?? '',
            subtitle: [
              '任务',
              mission['crew'] as String?,
              mission['state'] == 'running' ? '运行中' : '已停止',
              if ((mission['asks'] as List?)?.isNotEmpty ?? false) '有问题待回答',
            ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
            onMenu: live ? () => onMissionMenu(mission) : null,
          ),
        );
        for (final member in members) {
          children.add(
            session(
              member['session'] as String,
              label: '@${member['handle']}',
              indent: 24,
            ),
          );
        }
      }
      for (final tab in tabs.where((t) => t['project'] == project)) {
        final ids = [
          ...paneSessions(tab['panes']),
          ...((tab['shells'] as List?) ?? const []).cast<String>(),
        ].where(sessions.containsKey).toList();
        if (ids.length == 1) {
          children.add(session(ids.single));
          continue;
        }
        children.add(
          _GroupTile(
            icon: Icons.view_column_outlined,
            title: tab['name'] as String? ?? '',
            subtitle: '标签页 · ${ids.length} 个会话',
            onMenu: live ? () => onTabMenu(tab) : null,
          ),
        );
        for (final id in ids) {
          children.add(session(id, indent: 24));
        }
      }
    }

    for (final project in projects) {
      children.add(
        _Header(
          project['name'] as String? ?? '',
          icon: Icons.folder_outlined,
          onMenu: live ? () => onProjectMenu(project) : null,
        ),
      );
      final before = children.length;
      items(project['id'] as String);
      if (children.length == before) {
        children.add(const ListTile(dense: true, title: Text('还没有聊天或任务')));
      }
    }
    final before = children.length;
    items(null);
    final loose = sessions.keys.where((id) => !placed.contains(id)).toList();
    for (final id in loose) {
      children.add(session(id));
    }
    if (children.length > before) {
      children.insert(before, const _Header('其他'));
    }
    if (children.isEmpty) {
      children.add(const ListTile(title: Text('这台电脑上还没有会话，点「新建」开始。')));
    }
    children.add(const SizedBox(height: 88)); // Room above the button.
    return ListView(children: children);
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text, {this.icon, this.onMenu});
  final String text;
  final IconData? icon;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
    child: Row(
      children: [
        if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.titleSmall),
        ),
        if (onMenu != null)
          IconButton(
            tooltip: '工作区操作',
            icon: const Icon(Icons.more_horiz),
            onPressed: onMenu,
          ),
      ],
    ),
  );
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onMenu,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: onMenu == null
        ? null
        : IconButton(icon: const Icon(Icons.more_vert), onPressed: onMenu),
    onLongPress: onMenu,
  );
}

const _statusText = {
  'needsYou': '需要你',
  'working': '工作中',
  'idle': '空闲',
  'starting': '启动中',
  'stopped': '已停止',
  'error': '出错',
};

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.id,
    required this.session,
    required this.onTap,
    required this.onMenu,
    this.label,
    this.indent = 0,
  });

  final String id;
  final Map<String, dynamic> session;
  final String? label;
  final double indent;
  final VoidCallback? onTap;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final status = session['status'] as String? ?? '';
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsetsDirectional.only(start: 16 + indent, end: 4),
      leading: Icon(
        session['kind'] == 'shell' ? Icons.terminal : Icons.smart_toy_outlined,
        color: status == 'needsYou'
            ? colors.error
            : _isStopped(session)
            ? Theme.of(context).disabledColor
            : null,
      ),
      title: Text(_sessionTitle(session)),
      subtitle: Text(
        [
          ?label,
          ?session['runtime'] as String?,
          _statusText[status] ?? status,
        ].join(' · '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (session['unread'] == true)
            Icon(Icons.circle, size: 10, color: colors.primary),
          if (onMenu != null)
            IconButton(
              key: Key('menu-$id'),
              icon: const Icon(Icons.more_vert),
              onPressed: onMenu,
            ),
        ],
      ),
      onTap: onTap,
      onLongPress: onMenu,
    );
  }
}
