import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/core.dart';
import '../core/remote.dart';
import '../services.dart';

/// How many feed entries one page asks for.
const feedPage = 50;

/// A crew mission as a chat, as Runner's desktop shows it: the mission's feed
/// (what the members and the person post, questions and answers), a composer
/// that posts to everyone or to chosen members, and, behind the 成员 button,
/// each member, whose own session opens for a one-to-one conversation.
class MissionPage extends StatefulWidget {
  const MissionPage({
    super.key,
    required this.remote,
    required this.mission,
    required this.overview,
    required this.openSession,
  });

  final Remote remote;
  final String mission;

  /// The overview the computer page last had; pushes keep this page current.
  final Map<String, dynamic> overview;

  /// Opens a member's own session, as the computer page opens any session.
  final Future<void> Function(String session, String title) openSession;

  @override
  State<MissionPage> createState() => _MissionPageState();
}

class _MissionPageState extends State<MissionPage> {
  late Map<String, dynamic> _overview = widget.overview;

  /// The feed, oldest first.
  final _entries = <Map<String, dynamic>>[];
  final _seen = <String>{};

  /// The cursor for older entries; null once the start is reached.
  String? _before;
  var _loaded = false;
  var _loadingOlder = false;
  String? _error;

  var _showMembers = false;
  final _draft = TextEditingController();
  final _scroll = ScrollController();

  /// Who the next post goes to; empty is everyone.
  var _to = <String>[];
  var _sending = false;

  StreamSubscription<RouteEvent>? _pushes;
  var _wasConnected = true;

  Remote get _remote => widget.remote;

  @override
  void initState() {
    super.initState();
    _pushes = _remote.pushes.listen(_onPush);
    _remote.addListener(_onRemote);
    _open();
  }

  @override
  void dispose() {
    _pushes?.cancel();
    _remote.removeListener(_onRemote);
    if (_remote.connected && _remote.has('unfollow')) {
      unawaited(
        _remote
            .request('unfollow', {'mission': widget.mission})
            .catchError((_) => null),
      );
    }
    _draft.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Follows the mission, then reads its latest page; entries pushed in
  /// between are kept once.
  Future<void> _open() async {
    try {
      if (_remote.has('follow')) {
        await _remote.request('follow', {'mission': widget.mission});
      }
      final page =
          await _remote.request('feed', {
                'mission': widget.mission,
                'before': null,
                'limit': feedPage,
              })
              as Map;
      if (!mounted) return;
      setState(() {
        _add(_newestFirst(page), older: true);
        _before = page['before'] as String?;
        _loaded = true;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// A page's entries, which the host lists newest first.
  static List<Map<String, dynamic>> _newestFirst(Map page) =>
      ((page['entries'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .toList();

  /// Adds entries not shown yet: [older] ones (newest first) go above.
  void _add(List<Map<String, dynamic>> entries, {required bool older}) {
    final fresh = entries.where((e) => _seen.add(e['id'] as String)).toList();
    if (older) {
      _entries.insertAll(0, fresh.reversed);
    } else {
      _entries.addAll(fresh);
    }
  }

  Future<void> _loadOlder() async {
    final before = _before;
    if (before == null || _loadingOlder) return;
    setState(() => _loadingOlder = true);
    try {
      final page =
          await _remote.request('feed', {
                'mission': widget.mission,
                'before': before,
                'limit': feedPage,
              })
              as Map;
      if (!mounted) return;
      setState(() {
        _add(_newestFirst(page), older: true);
        _before = page['before'] as String?;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  void _onPush(RouteEvent event) {
    final message = event.message!;
    switch (event.type) {
      case 'feedAppended' when message['mission'] == widget.mission:
        setState(
          () => _add(
            ((message['entries'] as List?) ?? const [])
                .cast<Map<String, dynamic>>(),
            older: false,
          ),
        );
      case 'overview':
        setState(() => _overview = message);
      case 'status':
        final session = _sessions[message['session']];
        if (session == null) return;
        setState(() {
          for (final key in const ['status', 'reason', 'unread']) {
            session[key] = message[key];
          }
        });
    }
  }

  /// A reconnect opens a new route, which follows nothing: follow again and
  /// catch up on what was missed.
  void _onRemote() {
    final connected = _remote.connected;
    if (connected && !_wasConnected) unawaited(_open());
    _wasConnected = connected;
    if (mounted) setState(() {});
  }

  Map<String, dynamic>? get _mission =>
      ((_overview['missions'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .where((m) => m['id'] == widget.mission)
          .firstOrNull;

  Map<String, Map<String, dynamic>> get _sessions =>
      ((_overview['sessions'] as Map?) ?? const {})
          .cast<String, Map<String, dynamic>>();

  List<Map<String, dynamic>> get _members =>
      ((_mission?['members'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

  bool get _running => _mission?['state'] == 'running';

  /// Runner takes posts to a stopped mission too; they wait in its log.
  bool get _canPost => _remote.connected && _remote.has('post');

  /// The questions answered so far, by question id.
  Map<String, String> get _answers => {
    for (final e in _entries)
      if (e['kind'] == 'answer') e['question'] as String: e['text'] as String,
  };

  Future<void> _send() async {
    final text = _draft.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _remote.request('post', {
        'mission': widget.mission,
        'to': _to,
        'text': text,
      });
      _draft.clear();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _answer(String question, String text) async {
    try {
      await _remote.request('answer', {
        'mission': widget.mission,
        'question': question,
        'text': text,
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _answerFreely(String question, String prompt) async {
    final text = TextEditingController();
    final reply = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('回答'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(prompt),
            const SizedBox(height: 12),
            TextField(
              key: const Key('answerText'),
              controller: text,
              autofocus: true,
              minLines: 1,
              maxLines: 5,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('answerSend'),
            onPressed: () => Navigator.pop(dialog, text.text.trim()),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (reply != null && reply.isNotEmpty) await _answer(question, reply);
  }

  Future<void> _chooseRecipients() async {
    final chosen = await showModalBottomSheet<List<String>>(
      context: context,
      showDragHandle: true,
      builder: (_) => _RecipientSheet(
        handles: [for (final m in _members) m['handle'] as String],
        chosen: _to,
      ),
    );
    if (chosen != null && mounted) setState(() => _to = chosen);
  }

  void _talkTo(Map<String, dynamic> member) {
    final session = member['session'] as String;
    unawaited(widget.openSession(session, '@${member['handle']}'));
  }

  @override
  Widget build(BuildContext context) {
    final mission = _mission;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(mission?['title'] as String? ?? '任务'),
            Text(
              [
                mission?['crew'] as String?,
                _running ? '运行中' : '已停止',
                '${_members.length} 名成员',
              ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('members'),
            tooltip: _showMembers ? '收起成员' : '展开成员',
            isSelected: _showMembers,
            icon: const Icon(Icons.groups_outlined),
            selectedIcon: const Icon(Icons.groups),
            onPressed: () => setState(() => _showMembers = !_showMembers),
          ),
        ],
      ),
      body: Column(
        children: [
          ReconnectBanner(remote: _remote),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: _showMembers ? _membersPanel() : const SizedBox.shrink(),
          ),
          Expanded(child: _feed()),
          _composer(),
        ],
      ),
    );
  }

  Widget _membersPanel() {
    final theme = Theme.of(context);
    return Material(
      key: const Key('membersPanel'),
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_members.isEmpty) const ListTile(title: Text('这个任务还没有成员')),
          for (final member in _members)
            Builder(
              builder: (context) {
                final handle = member['handle'] as String;
                final session = _sessions[member['session']];
                final status = session?['status'] as String?;
                return ListTile(
                  key: Key('member.$handle'),
                  leading: CircleAvatar(
                    child: Text(handle.characters.first.toUpperCase()),
                  ),
                  title: Text('@$handle'),
                  subtitle: Text(
                    [
                      ?_memberStatus[status],
                      if (session?['title'] case final String title
                          when title.isNotEmpty)
                        title,
                    ].join(' · '),
                  ),
                  onTap: _remote.connected ? () => _talkTo(member) : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: Key('memberMention.$handle'),
                        tooltip: '在群里只发给 @$handle',
                        icon: const Icon(Icons.alternate_email),
                        onPressed: _canPost
                            ? () => setState(() => _to = [handle])
                            : null,
                      ),
                      IconButton(
                        key: Key('memberChat.$handle'),
                        tooltip: '单独对话',
                        icon: const Icon(Icons.chat_bubble_outline),
                        onPressed: _remote.connected
                            ? () => _talkTo(member)
                            : null,
                      ),
                    ],
                  ),
                );
              },
            ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  Widget _feed() {
    if (!_loaded) {
      return Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
      );
    }
    final answers = _answers;
    final shown = [
      for (final e in _entries)
        if (_visible(e)) e,
    ];
    // Newest at the bottom, where the list starts.
    return ListView.builder(
      key: const Key('feed'),
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: shown.length + 1,
      itemBuilder: (context, index) {
        if (index == shown.length) {
          if (_before != null) {
            return Center(
              child: TextButton(
                key: const Key('older'),
                onPressed: _loadingOlder ? null : _loadOlder,
                child: Text(_loadingOlder ? '正在加载…' : '加载更早的消息'),
              ),
            );
          }
          return shown.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('还没有消息', textAlign: TextAlign.center),
                )
              : const SizedBox(height: 8);
        }
        return _entry(shown[shown.length - 1 - index], answers);
      },
    );
  }

  /// Entries a person reads; status bookkeeping and answers (shown on their
  /// question) are left out.
  static bool _visible(Map<String, dynamic> entry) => switch (entry['kind']) {
    'answer' => false,
    'signal' => !const {
      'session_status',
      'runner_status',
      'inbox_read',
      'ask_human',
    }.contains(entry['signal']),
    _ => true,
  };

  Widget _entry(Map<String, dynamic> e, Map<String, String> answers) {
    final from = e['from'] as String? ?? '';
    final to = ((e['to'] as List?) ?? const []).cast<String>();
    final key = Key('entry.${e['id']}');
    switch (e['kind']) {
      case 'message':
        return _Bubble(
          key: key,
          mine: from == 'human',
          author: from == 'human' ? '你' : '@$from',
          to: to,
          time: e['ts'] as String?,
          text: e['text'] as String? ?? '',
        );
      case 'ask':
        final question = e['question'] as String;
        return _AskCard(
          key: key,
          from: from,
          time: e['ts'] as String?,
          prompt: e['prompt'] as String? ?? '',
          choices: (e['choices'] as List?)?.cast<String>(),
          answer: answers[question],
          canAnswer: _remote.connected && _remote.has('answer'),
          onChoice: (choice) => _answer(question, choice),
          onReply: () => _answerFreely(question, e['prompt'] as String? ?? ''),
        );
      case 'signal':
        final payload = (e['payload'] as Map?)?.cast<String, dynamic>() ?? {};
        switch (e['signal']) {
          case 'human_said':
            return _Bubble(
              key: key,
              mine: true,
              author: '你',
              to: recipients(payload['target']) ?? to,
              time: e['ts'] as String?,
              text: payload['text'] as String? ?? '',
            );
          case 'mission_goal':
            return _Notice(
              key: key,
              icon: Icons.flag_outlined,
              title: '任务目标',
              text: payload['text'] as String? ?? '',
            );
          case 'mission_start':
            return _Divider(key: key, text: '任务开始');
          case 'feedEntryTooLarge':
            return _Divider(
              key: key,
              text: payload['message'] as String? ?? '这条内容太大，请在电脑上查看',
            );
          default:
            final text = payload['text'] as String?;
            return _Divider(
              key: key,
              text: [
                if (from.isNotEmpty && from != 'system') '@$from',
                e['signal'] as String? ?? '',
                ?text,
              ].join(' · '),
            );
        }
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _composer() {
    final theme = Theme.of(context);
    final hint = !_remote.has('post')
        ? '这台电脑不支持发消息'
        : !_running
        ? '任务已停止，消息会先记在任务里'
        : '发消息；开头写 @代号 只发给这名成员';
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ActionChip(
              key: const Key('recipients'),
              avatar: const Icon(Icons.send_outlined, size: 16),
              label: Text(
                _to.isEmpty
                    ? '发给：所有人'
                    : '发给：${_to.map((h) => '@$h').join(' ')}',
              ),
              onPressed: _canPost ? _chooseRecipients : null,
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('draft'),
                    controller: _draft,
                    enabled: _canPost,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: hint,
                      border: InputBorder.none,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                IconButton(
                  key: const Key('send'),
                  tooltip: '发送',
                  icon: _sending
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  onPressed: _canPost && _draft.text.trim().isNotEmpty
                      ? _send
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

const _memberStatus = {
  'needsYou': '需要你',
  'working': '工作中',
  'idle': '空闲',
  'starting': '启动中',
  'stopped': '已停止',
  'error': '出错',
};

/// The handles a post went to: Runner writes one as a string, several as a
/// list; null when it says none.
List<String>? recipients(Object? target) => switch (target) {
  final String one => [one],
  final List several => several.whereType<String>().toList(),
  _ => null,
};

/// `HH:mm` in local time, or nothing for a time that does not parse.
String feedTime(String? ts) {
  final time = ts == null ? null : DateTime.tryParse(ts)?.toLocal();
  if (time == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}';
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.mine,
    required this.author,
    required this.to,
    required this.time,
    required this.text,
  });

  final bool mine;
  final String author;
  final List<String> to;
  final String? time;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final header = [
      author,
      to.isEmpty ? '→ 所有人' : '→ ${to.map((h) => '@$h').join(' ')}',
      feedTime(time),
    ].where((s) => s.isNotEmpty).join('  ');
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.85,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Text(
                header,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.outline,
                ),
              ),
              const SizedBox(height: 2),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: mine
                      ? colors.primaryContainer
                      : colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: SelectableText(text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AskCard extends StatelessWidget {
  const _AskCard({
    super.key,
    required this.from,
    required this.time,
    required this.prompt,
    required this.choices,
    required this.answer,
    required this.canAnswer,
    required this.onChoice,
    required this.onReply,
  });

  final String from;
  final String? time;
  final String prompt;
  final List<String>? choices;
  final String? answer;
  final bool canAnswer;
  final void Function(String choice) onChoice;
  final VoidCallback onReply;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final answered = answer != null;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: answered ? null : theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ['@$from 提问', feedTime(time)].join('  '),
              style: theme.textTheme.labelSmall,
            ),
            const SizedBox(height: 4),
            SelectableText(prompt, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 8),
            if (answered)
              Text(
                '已回答：$answer',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final choice in choices ?? const <String>[])
                    FilledButton.tonal(
                      key: Key('choice.$choice'),
                      onPressed: canAnswer ? () => onChoice(choice) : null,
                      child: Text(choice),
                    ),
                  OutlinedButton(
                    key: const Key('reply'),
                    onPressed: canAnswer ? onReply : null,
                    child: Text(choices == null ? '回答' : '其他回答'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card.outlined(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title, style: theme.textTheme.labelLarge),
        subtitle: SelectableText(text),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Flexible(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

/// Picks who a post goes to: everyone, or some members.
class _RecipientSheet extends StatefulWidget {
  const _RecipientSheet({required this.handles, required this.chosen});

  final List<String> handles;
  final List<String> chosen;

  @override
  State<_RecipientSheet> createState() => _RecipientSheetState();
}

class _RecipientSheetState extends State<_RecipientSheet> {
  late final _chosen = {...widget.chosen};

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CheckboxListTile(
          key: const Key('toEveryone'),
          title: const Text('所有人'),
          value: _chosen.isEmpty,
          onChanged: (_) => setState(_chosen.clear),
        ),
        for (final handle in widget.handles)
          CheckboxListTile(
            key: Key('to.$handle'),
            title: Text('@$handle'),
            value: _chosen.contains(handle),
            onChanged: (on) => setState(
              () => on == true ? _chosen.add(handle) : _chosen.remove(handle),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('recipientsDone'),
              onPressed: () => Navigator.pop(context, [
                for (final h in widget.handles)
                  if (_chosen.contains(h)) h,
              ]),
              child: const Text('确定'),
            ),
          ),
        ),
      ],
    ),
  );
}
