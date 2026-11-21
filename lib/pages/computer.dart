import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/core.dart';
import '../core/store.dart';
import '../services.dart';
import 'terminal.dart';

/// One connected computer: its chats and missions' sessions.
class ComputerPage extends StatefulWidget {
  const ComputerPage({
    super.key,
    required this.account,
    required this.computer,
    required this.route,
  });

  final Account account;
  final Map<String, dynamic> computer;
  final int route;

  @override
  State<ComputerPage> createState() => _ComputerPageState();
}

class _ComputerPageState extends State<ComputerPage> {
  late Core _core;
  StreamSubscription<RouteEvent>? _events;
  Map<String, dynamic>? _overview;
  String? _closed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_events != null) return;
    _core = Services.of(context).core;
    _events = _core.routeEvents
        .where((e) => e.route == widget.route)
        .listen(_onEvent);
    _refresh();
  }

  @override
  void dispose() {
    _events?.cancel();
    if (_closed == null) _core.call('close', {'route': widget.route});
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final overview = await _core.request(widget.route, {'type': 'overview'});
      if (mounted) setState(() => _overview = overview as Map<String, dynamic>);
    } catch (e) {
      if (mounted && _closed == null) showError(context, e);
    }
  }

  void _onEvent(RouteEvent event) {
    if (event.closed) {
      setState(() => _closed = event.error ?? '连接已关闭');
      return;
    }
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

  @override
  Widget build(BuildContext context) {
    final overview = _overview;
    return Scaffold(
      appBar: AppBar(title: Text(widget.computer['name'] as String? ?? '电脑')),
      body: Column(
        children: [
          if (_closed != null)
            MaterialBanner(
              content: Text('连接已断开：$_closed'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('返回重新连接'),
                ),
              ],
            ),
          Expanded(
            child: overview == null
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: _SessionList(
                      overview: overview,
                      onOpen: _closed == null ? _openSession : null,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  void _openSession(String id, Map<String, dynamic> session) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalPage(
          route: widget.route,
          session: id,
          title: session['title'] as String? ?? '',
        ),
      ),
    );
  }
}

/// Sessions grouped the way the desktop sidebar groups them: missions, then chats.
class _SessionList extends StatelessWidget {
  const _SessionList({required this.overview, required this.onOpen});

  final Map<String, dynamic> overview;
  final void Function(String id, Map<String, dynamic> session)? onOpen;

  @override
  Widget build(BuildContext context) {
    final sessions = (overview['sessions'] as Map<String, dynamic>? ?? {})
        .cast<String, Map<String, dynamic>>();
    final missions = (overview['missions'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final inMissions = <String>{};
    final children = <Widget>[];

    for (final mission in missions) {
      final members = (mission['members'] as List? ?? const [])
          .cast<Map<String, dynamic>>()
          .where((m) => sessions.containsKey(m['session']))
          .toList();
      if (members.isEmpty) continue;
      children.add(_Header('任务 · ${mission['title']}'));
      for (final member in members) {
        final id = member['session'] as String;
        inMissions.add(id);
        children.add(
          _SessionTile(
            id: id,
            session: sessions[id]!,
            label: '@${member['handle']}',
            onOpen: onOpen,
          ),
        );
      }
    }

    final chats =
        sessions.entries.where((e) => !inMissions.contains(e.key)).toList()
          ..sort(
            (a, b) => (a.value['title'] as String? ?? '').compareTo(
              b.value['title'] as String? ?? '',
            ),
          );
    if (chats.isNotEmpty) {
      children.add(const _Header('聊天'));
      for (final chat in chats) {
        children.add(
          _SessionTile(id: chat.key, session: chat.value, onOpen: onOpen),
        );
      }
    }
    if (children.isEmpty) {
      children.add(const ListTile(title: Text('这台电脑上还没有会话')));
    }
    return ListView(children: children);
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
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
    required this.onOpen,
    this.label,
  });

  final String id;
  final Map<String, dynamic> session;
  final String? label;
  final void Function(String id, Map<String, dynamic> session)? onOpen;

  @override
  Widget build(BuildContext context) {
    final status = session['status'] as String? ?? '';
    final colors = Theme.of(context).colorScheme;
    final title = session['title'] as String? ?? '';
    return ListTile(
      leading: Icon(
        session['kind'] == 'shell' ? Icons.terminal : Icons.smart_toy_outlined,
        color: status == 'needsYou' ? colors.error : null,
      ),
      title: Text(title.isEmpty ? '未命名' : title),
      subtitle: Text(
        [
          ?label,
          ?session['runtime'] as String?,
          _statusText[status] ?? status,
        ].join(' · '),
      ),
      trailing: session['unread'] == true
          ? Icon(Icons.circle, size: 10, color: colors.primary)
          : null,
      onTap: onOpen == null ? null : () => onOpen!(id, session),
    );
  }
}
