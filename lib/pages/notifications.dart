import 'package:material_ui/material_ui.dart';

import '../core/store.dart';
import '../services.dart';

/// Bark's interruption levels, with "" for Bark's default.
const barkLevels = {
  '': '默认',
  'active': '立即（active）',
  'timeSensitive': '时效性（timeSensitive）',
  'passive': '被动（passive）',
  'critical': '重要警告（critical）',
};

/// Ntfy's priorities, with 0 for the server's default.
const ntfyPriorities = {
  0: '默认',
  1: '1 最低',
  2: '2 低',
  3: '3 普通',
  4: '4 高',
  5: '5 最高',
};

/// "Name: value" lines as a header map; lines without a name are skipped.
Map<String, String> parseHeaders(String text) => {
  for (final line in text.split('\n'))
    if (line.indexOf(':') case final colon when colon > 0)
      if (line.substring(0, colon).trim() case final name when name.isNotEmpty)
        name: line.substring(colon + 1).trim(),
};

/// The header map as "Name: value" lines.
String formatHeaders(Map<String, dynamic>? headers) => [
  for (final MapEntry(:key, :value) in (headers ?? const {}).entries)
    '$key: $value',
].join('\n');

/// The account's push notifications: where runner-server sends them, which
/// kinds it sends, and the computers it listens to.
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key, required this.account});

  final Account account;

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  var _started = false;
  var _loading = true;
  String? _loadError;
  var _busy = false;

  var _kind = 'none';
  final _barkServer = TextEditingController(text: 'https://api.day.app');
  final _barkKey = TextEditingController();
  final _barkGroup = TextEditingController();
  final _barkSound = TextEditingController();
  var _barkLevel = '';
  final _ntfyServer = TextEditingController(text: 'https://ntfy.sh');
  final _ntfyTopic = TextEditingController();
  final _ntfyToken = TextEditingController();
  var _ntfyPriority = 0;
  final _ntfyTags = TextEditingController();
  final _webhookUrl = TextEditingController();
  final _webhookHeaders = TextEditingController();
  final _webhookTemplate = TextEditingController();
  final _webhookGroup = TextEditingController();
  var _events = {'input': true, 'finished': true, 'failed': true};

  List<Map<String, dynamic>>? _watchers;
  String? _watchersError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  @override
  void dispose() {
    for (final controller in [
      _barkServer,
      _barkKey,
      _barkGroup,
      _barkSound,
      _ntfyServer,
      _ntfyTopic,
      _ntfyToken,
      _ntfyTags,
      _webhookUrl,
      _webhookHeaders,
      _webhookTemplate,
      _webhookGroup,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, Object?> body = const {},
  ]) => Services.of(
    context,
  ).core.notify(widget.account.origin, widget.account.credential, method, body);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final settings = await _call('GetSettings');
      if (!mounted) return;
      setState(() => _apply(settings));
    } catch (e) {
      if (mounted) setState(() => _loadError = e.toString());
    }
    if (mounted) setState(() => _loading = false);
    await _loadWatchers();
  }

  Future<void> _loadWatchers() async {
    try {
      final reply = await _call('ListWatchers');
      if (!mounted) return;
      setState(() {
        _watchers = ((reply['watchers'] as List?) ?? const [])
            .cast<Map<String, dynamic>>();
        _watchersError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _watchersError = e.toString());
    }
  }

  void _apply(Map<String, dynamic> settings) {
    final events = settings['events'] as Map<String, dynamic>?;
    _events = {
      for (final kind in ['input', 'finished', 'failed'])
        kind: events?[kind] as bool? ?? true,
    };
    final channel = settings['channel'] as Map<String, dynamic>?;
    String text(String key) => channel?[key] as String? ?? '';
    switch (channel?['kind']) {
      case 'bark':
        _kind = 'bark';
        if (text('server').isNotEmpty) _barkServer.text = text('server');
        _barkKey.text = text('deviceKey');
        _barkGroup.text = text('group');
        _barkSound.text = text('sound');
        _barkLevel = barkLevels.containsKey(text('level')) ? text('level') : '';
      case 'ntfy':
        _kind = 'ntfy';
        if (text('server').isNotEmpty) _ntfyServer.text = text('server');
        _ntfyTopic.text = text('topic');
        _ntfyToken.text = text('token');
        final priority = (channel?['priority'] as num?)?.toInt() ?? 0;
        _ntfyPriority = ntfyPriorities.containsKey(priority) ? priority : 0;
        _ntfyTags.text = text('tags');
      case 'webhook':
        _kind = 'webhook';
        _webhookUrl.text = text('url');
        _webhookHeaders.text = formatHeaders(
          channel?['headers'] as Map<String, dynamic>?,
        );
        _webhookTemplate.text = text('template');
        _webhookGroup.text = text('group');
      default:
        _kind = 'none';
    }
  }

  /// The channel as the server takes it, or a message saying what is missing.
  (Map<String, Object?>?, String?) _channel() {
    String text(TextEditingController c) => c.text.trim();
    switch (_kind) {
      case 'bark':
        if (text(_barkKey).isEmpty) return (null, '请填写 Bark 的 Device Key');
        return (
          {
            'kind': 'bark',
            'server': text(_barkServer).isEmpty
                ? 'https://api.day.app'
                : text(_barkServer),
            'deviceKey': text(_barkKey),
            'group': text(_barkGroup),
            'sound': text(_barkSound),
            'level': _barkLevel,
          },
          null,
        );
      case 'ntfy':
        if (text(_ntfyTopic).isEmpty) return (null, '请填写 Ntfy 的主题');
        return (
          {
            'kind': 'ntfy',
            'server': text(_ntfyServer).isEmpty
                ? 'https://ntfy.sh'
                : text(_ntfyServer),
            'topic': text(_ntfyTopic),
            'token': text(_ntfyToken),
            'priority': _ntfyPriority,
            'tags': text(_ntfyTags),
          },
          null,
        );
      case 'webhook':
        if (text(_webhookUrl).isEmpty) return (null, '请填写 Webhook 的 URL');
        return (
          {
            'kind': 'webhook',
            'url': text(_webhookUrl),
            'headers': parseHeaders(_webhookHeaders.text),
            'template': _webhookTemplate.text.trim(),
            'group': text(_webhookGroup),
          },
          null,
        );
    }
    return (null, null);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _save({bool quiet = false}) async {
    final (channel, problem) = _channel();
    if (problem != null) {
      showMessage(context, problem);
      return false;
    }
    final saved = await _call('SetSettings', {
      'channel': channel,
      'events': _events,
    });
    if (!mounted) return false;
    setState(() => _apply(saved));
    if (!quiet) showMessage(context, '已保存');
    return true;
  }

  void _test() => _run(() async {
    if (!await _save(quiet: true)) return;
    await _call('Test');
    if (mounted) showMessage(context, '已发送测试通知');
  });

  Future<void> _pair(Map<String, dynamic> watcher) async {
    final pin = await askWatcherPin(context, watcher['name'] as String? ?? '');
    if (pin == null || pin.isEmpty || !mounted) return;
    await _run(() async {
      await _call('PairWatcher', {'computer': watcher['computer'], 'pin': pin});
      if (mounted) showMessage(context, '已配对');
      await _loadWatchers();
    });
  }

  Future<void> _unpair(Map<String, dynamic> watcher) => _run(() async {
    await _call('UnpairWatcher', {'computer': watcher['computer']});
    if (mounted) showMessage(context, '已取消配对');
    await _loadWatchers();
  });

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );

  Widget _field(
    String key,
    TextEditingController controller,
    String label, {
    String? hint,
    bool obscure = false,
    int? lines = 1,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: TextField(
      key: Key(key),
      controller: controller,
      obscureText: obscure,
      minLines: lines == null ? 3 : 1,
      maxLines: obscure ? 1 : lines,
      keyboardType: lines == null ? TextInputType.multiline : keyboard,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _dropdown<T>(
    String key,
    String label,
    T value,
    Map<T, String> items,
    ValueChanged<T> onChanged,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: DropdownButtonFormField<T>(
      key: Key(key),
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final MapEntry(:key, :value) in items.entries)
          DropdownMenuItem(value: key, child: Text(value)),
      ],
      onChanged: (value) {
        if (value != null) setState(() => onChanged(value));
      },
    ),
  );

  List<Widget> _fields() => switch (_kind) {
    'bark' => [
      _field('barkServer', _barkServer, '服务器', keyboard: TextInputType.url),
      _field('barkKey', _barkKey, 'Device Key'),
      _field('barkGroup', _barkGroup, '分组', hint: '可选'),
      _field('barkSound', _barkSound, '铃声', hint: '可选，如 minuet'),
      _dropdown(
        'barkLevel',
        '中断级别',
        _barkLevel,
        barkLevels,
        (v) => _barkLevel = v,
      ),
    ],
    'ntfy' => [
      _field('ntfyServer', _ntfyServer, '服务器', keyboard: TextInputType.url),
      _field('ntfyTopic', _ntfyTopic, '主题'),
      _field('ntfyToken', _ntfyToken, '访问令牌', hint: '可选', obscure: true),
      _dropdown(
        'ntfyPriority',
        '优先级',
        _ntfyPriority,
        ntfyPriorities,
        (v) => _ntfyPriority = v,
      ),
      _field('ntfyTags', _ntfyTags, '标签', hint: '可选，用逗号分隔'),
    ],
    'webhook' => [
      _field('webhookUrl', _webhookUrl, 'URL', keyboard: TextInputType.url),
      _field(
        'webhookHeaders',
        _webhookHeaders,
        '请求头',
        hint: '每行一个，如 Authorization: Bearer xxx',
        lines: null,
      ),
      _field(
        'webhookTemplate',
        _webhookTemplate,
        '消息模板',
        hint: '可选',
        lines: null,
      ),
      _field(
        'webhookGroup',
        _webhookGroup,
        '分组',
        hint: '可选，{{group}} 的值，默认 Runner Remote',
      ),
      _note(webhookVariablesNote),
    ],
    _ => const [],
  };

  Widget _watcherTile(Map<String, dynamic> watcher) {
    final id = watcher['computer'] as String? ?? '';
    final online = watcher['online'] == true;
    final paired = watcher['paired'] == true;
    final error = watcher['error'] as String?;
    final state = !paired
        ? '未配对'
        : error != null && error.isNotEmpty
        ? '错误：$error'
        : watcher['watching'] == true
        ? '监听中'
        : '已配对';
    return ListTile(
      key: Key('watcher.$id'),
      leading: Icon(
        Icons.computer,
        color: online ? null : Theme.of(context).disabledColor,
      ),
      title: Text(watcher['name'] as String? ?? id),
      subtitle: Text('${online ? '在线' : '离线'} · $state'),
      trailing: paired
          ? TextButton(
              key: Key('watcherUnpair.$id'),
              onPressed: _busy ? null : () => _unpair(watcher),
              child: const Text('取消配对'),
            )
          : TextButton(
              key: Key('watcherPair.$id'),
              onPressed: _busy || !online ? null : () => _pair(watcher),
              child: const Text('配对'),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_loadError != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_loadError!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('notifyRetry'),
                onPressed: _load,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    } else {
      body = ListView(
        key: const Key('notifications'),
        children: [
          _note(
            '通知由服务器发送，只发给最近接管该会话的手机'
            '（没有时发给最近连接那台电脑的手机）。'
            '标题为“Runner Remote”，内容如“[需要输入]:会话名”。',
          ),
          _heading('推送方式'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SegmentedButton<String>(
              key: const Key('notifyKind'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'none', label: Text('不推送')),
                ButtonSegment(value: 'bark', label: Text('Bark')),
                ButtonSegment(value: 'ntfy', label: Text('Ntfy')),
                ButtonSegment(value: 'webhook', label: Text('Webhook')),
              ],
              selected: {_kind},
              onSelectionChanged: (selected) =>
                  setState(() => _kind = selected.single),
            ),
          ),
          ..._fields(),
          _heading('通知类型'),
          for (final (kind, label) in const [
            ('input', '需要输入'),
            ('finished', '已完成'),
            ('failed', '失败'),
          ])
            SwitchListTile(
              key: Key('notifyEvent.$kind'),
              title: Text(label),
              value: _events[kind] ?? true,
              onChanged: (on) => setState(() => _events[kind] = on),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: const Key('notifySave'),
                  onPressed: _busy ? null : () => _run(_save),
                  child: const Text('保存'),
                ),
                OutlinedButton(
                  key: const Key('notifyTest'),
                  onPressed: _busy || _kind == 'none' ? null : _test,
                  child: const Text('发送测试通知'),
                ),
              ],
            ),
          ),
          const Divider(),
          _heading('服务器监听'),
          _note(
            '服务器要与电脑配对后才能知道会话的状态。它以单独的设备'
            '“Runner Remote 通知服务”配对，只读取会话状态。',
          ),
          if (_watchersError != null)
            _note(_watchersError!)
          else if (_watchers == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_watchers!.isEmpty)
            _note('这个账户下还没有电脑。')
          else
            for (final watcher in _watchers!) _watcherTile(watcher),
          const SizedBox(height: 24),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('通知'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: body,
    );
  }
}

/// Asks for the PIN `runner remote pin` shows on the computer [name].
Future<String?> askWatcherPin(BuildContext context, String name) {
  final pin = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('让服务器与 $name 配对'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '在电脑上运行 runner remote pin，输入它显示的 6 位 PIN。'
            '服务器将以“Runner Remote 通知服务”配对，只读取会话状态。',
          ),
          TextField(
            key: const Key('watcherPin'),
            controller: pin,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(labelText: 'PIN'),
            onSubmitted: (value) => Navigator.pop(context, value.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('watcherPinOk'),
          onPressed: () => Navigator.pop(context, pin.text.trim()),
          child: const Text('配对'),
        ),
      ],
    ),
  );
}

/// What a webhook template can use; matches runner-server's TEMPLATE_VARIABLES.
const webhookVariablesNote =
    '留空时 POST 一个包含全部字段的 JSON。填写时按原样发送，并替换这些变量（值按 JSON 字符串转义）：\n'
    '{{title}} 标题 · {{message}} 内容（同 {{body}}）\n'
    '{{event}} 事件 input/finished/failed · {{event_name}} 需要输入/已完成/失败\n'
    '{{session}} 会话名 · {{session_id}} · {{computer}} 电脑名 · {{computer_id}}\n'
    '{{group}} 分组 · {{icon_url}} 图标地址\n'
    '{{goto_url}} 网页跳转：打开网页后转到 App 中的会话\n'
    '{{goto_url_schema}} 直接跳转：runner-remote:// 直接打开 App\n'
    '{{date}} 日期 · {{time}} 时间 · {{datetime}} · {{timestamp}} 秒';
