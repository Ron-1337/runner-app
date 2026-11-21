import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/core.dart';
import '../core/store.dart';
import '../services.dart';

/// What one computer reported to the dashboard.
class ComputerReport {
  ComputerReport({
    required this.account,
    required this.computer,
    this.sessions = const {},
    this.usage = const [],
    this.unpaired = false,
    this.error,
  });

  final Account account;
  final Map<String, dynamic> computer;

  /// Session id to session, from the computer's overview.
  final Map<String, Map<String, dynamic>> sessions;

  /// The agents' usage: `{name, value: {windows: [...]}, error}`.
  final List<Map<String, dynamic>> usage;

  /// No keys for it on this phone yet: pairing needs its PIN.
  final bool unpaired;
  final String? error;

  String get name => computer['name'] as String? ?? '';
}

/// Connects to [computer], reads its sessions and usage, and closes the route.
Future<ComputerReport> probeComputer(
  Core core,
  Store store,
  Account account,
  Map<String, dynamic> computer,
) async {
  final id = computer['id'] as String;
  final pairing = await store.pairing(account, id);
  if (pairing == null || pairing.fingerprint != computer['fingerprint']) {
    return ComputerReport(account: account, computer: computer, unpaired: true);
  }
  int? route;
  try {
    final opened =
        await core.call('connect', {
              'origin': account.origin,
              'credential': account.credential,
              'computer': id,
              'clientKey': pairing.clientKey,
              'hostKey': pairing.hostKey,
            })
            as Map<String, dynamic>;
    route = opened['route'] as int;
    final features = {
      ...?((opened['welcome'] as Map?)?['features'] as List?)?.cast<String>(),
    };
    final overview = features.contains('overview')
        ? await core.request(route, {'type': 'overview'}) as Map?
        : null;
    final usage = features.contains('usage')
        ? await core.request(route, {'type': 'usage', 'popover': true}) as Map?
        : null;
    return ComputerReport(
      account: account,
      computer: computer,
      sessions: ((overview?['sessions'] as Map?) ?? const {})
          .cast<String, Map<String, dynamic>>(),
      usage: ((usage?['agents'] as List?) ?? const [])
          .cast<Map<String, dynamic>>(),
    );
  } catch (e) {
    return ComputerReport(
      account: account,
      computer: computer,
      error: e is CoreException ? e.message : e.toString(),
    );
  } finally {
    if (route != null) {
      unawaited(core.call('close', {'route': route}).catchError((_) => null));
    }
  }
}

/// Every account's computers at a glance, their sessions across computers,
/// and the agents' usage. Sessions and usage come from connecting to each
/// online computer this phone is paired with.
class DashboardView extends StatefulWidget {
  const DashboardView({
    super.key,
    required this.accounts,
    required this.computers,
    required this.onOpenSession,
    required this.onRefreshComputers,
  });

  final List<Account> accounts;

  /// Account id to its computers, as the server lists them.
  final Map<String, List<Map<String, dynamic>>> computers;
  final void Function(
    Account account,
    Map<String, dynamic> computer,
    String session,
  )
  onOpenSession;
  final Future<void> Function() onRefreshComputers;

  @override
  State<DashboardView> createState() => DashboardViewState();
}

class DashboardViewState extends State<DashboardView> {
  List<ComputerReport>? _reports;
  var _loading = false;

  /// The online computers last read, to read again when the list changes.
  String? _probed;

  String get _online => [
    for (final account in widget.accounts)
      for (final computer in widget.computers[account.id] ?? const [])
        if (computer['online'] == true) '${account.id}/${computer['id']}',
  ].join(',');

  @override
  void didUpdateWidget(DashboardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_online != _probed && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) refresh();
      });
    }
  }

  /// Reconnects to the computers and reads them again.
  Future<void> refresh() async {
    if (_loading) return;
    setState(() => _loading = true);
    _probed = _online;
    final services = Services.of(context);
    final probes = <Future<ComputerReport>>[
      for (final account in widget.accounts)
        for (final computer in widget.computers[account.id] ?? const [])
          if (computer['online'] == true)
            probeComputer(
              services.core,
              services.store,
              account,
              computer,
            ).timeout(
              const Duration(seconds: 20),
              onTimeout: () => ComputerReport(
                account: account,
                computer: computer,
                error: '连接超时',
              ),
            ),
    ];
    final reports = await Future.wait(probes);
    if (!mounted) return;
    setState(() {
      _reports = reports;
      _loading = false;
    });
  }

  Future<void> _pullToRefresh() async {
    await widget.onRefreshComputers();
    await refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reports == null && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) refresh();
      });
    }
  }

  Widget _card(String title, List<Widget> children, {Widget? trailing}) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleMedium),
                  ),
                  ?trailing,
                ],
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, int value, {Color? color, Key? key}) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        key: key,
        children: [
          Text(
            '$value',
            style: theme.textTheme.headlineSmall?.copyWith(color: color),
          ),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _devices() {
    final all = [
      for (final account in widget.accounts)
        for (final computer in widget.computers[account.id] ?? const [])
          (account, computer),
    ];
    final online = all.where((e) => e.$2['online'] == true).length;
    final colors = Theme.of(context).colorScheme;
    return _card('设备', [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            _stat(
              '在线',
              online,
              color: colors.primary,
              key: const Key('statOnline'),
            ),
            _stat('离线', all.length - online, key: const Key('statOffline')),
            _stat('账户', widget.accounts.length),
          ],
        ),
      ),
      for (final (account, computer) in all)
        ListTile(
          dense: true,
          leading: Icon(
            Icons.circle,
            size: 10,
            color: computer['online'] == true
                ? colors.primary
                : Theme.of(context).disabledColor,
          ),
          title: Text(computer['name'] as String? ?? ''),
          subtitle: Text(
            [
              if (widget.accounts.length > 1) account.label,
              computer['online'] == true
                  ? '在线${_since(computer['connectedAt'], '自 ')}'
                  : '离线${_since(computer['lastSeenAt'], ' · 最后在线 ')}',
            ].join(' · '),
          ),
        ),
      if (all.isEmpty) const ListTile(dense: true, title: Text('还没有电脑')),
    ]);
  }

  static const _statusOrder = ['needsYou', 'working', 'starting', 'idle'];
  static const _statusText = {
    'needsYou': '需要你',
    'working': '工作中',
    'starting': '启动中',
    'idle': '空闲',
    'stopped': '已停止',
    'error': '出错',
  };

  Widget _sessions(List<ComputerReport> reports) {
    final colors = Theme.of(context).colorScheme;
    final entries = [
      for (final report in reports)
        for (final MapEntry(key: id, value: session) in report.sessions.entries)
          (report, id, session),
    ];
    int count(bool Function(String) test) =>
        entries.where((e) => test(e.$3['status'] as String? ?? '')).length;
    final live =
        entries.where((e) => _statusOrder.contains(e.$3['status'])).toList()
          ..sort(
            (a, b) => _statusOrder
                .indexOf(a.$3['status'] as String)
                .compareTo(_statusOrder.indexOf(b.$3['status'] as String)),
          );
    final unpaired = reports.where((r) => r.unpaired).toList();
    final failed = reports.where((r) => r.error != null).toList();
    return _card('会话', [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            _stat(
              '需要你',
              count((s) => s == 'needsYou'),
              color: colors.error,
              key: const Key('statNeedsYou'),
            ),
            _stat(
              '工作中',
              count((s) => s == 'working' || s == 'starting'),
              color: colors.primary,
              key: const Key('statWorking'),
            ),
            _stat('空闲', count((s) => s == 'idle'), key: const Key('statIdle')),
            _stat(
              '已停止',
              count((s) => s == 'stopped' || s == 'error'),
              key: const Key('statStopped'),
            ),
          ],
        ),
      ),
      for (final (report, id, session) in live)
        ListTile(
          key: Key('dashboardSession-$id'),
          dense: true,
          leading: Icon(
            session['kind'] == 'shell'
                ? Icons.terminal
                : Icons.smart_toy_outlined,
            color: session['status'] == 'needsYou' ? colors.error : null,
          ),
          title: Text(_title(session)),
          subtitle: Text(
            [
              report.name,
              ?session['runtime'] as String?,
              _statusText[session['status']] ?? '',
            ].join(' · '),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () =>
              widget.onOpenSession(report.account, report.computer, id),
        ),
      if (reports.isNotEmpty && live.isEmpty)
        const ListTile(dense: true, title: Text('没有进行中的会话')),
      if (unpaired.isNotEmpty)
        _note(
          '${unpaired.map((r) => r.name).join('、')} 还没有配对，在「电脑」中打开并输入 PIN 后会显示在这里。',
        ),
      for (final report in failed) _note('${report.name}：${report.error}'),
    ]);
  }

  Widget _usage(List<ComputerReport> reports) {
    final withUsage = reports.where((r) => r.usage.isNotEmpty).toList();
    final theme = Theme.of(context);
    return _card('用量', [
      for (final report in withUsage) ...[
        if (withUsage.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(report.name, style: theme.textTheme.labelLarge),
          ),
        for (final agent in report.usage) _agentUsage(agent),
      ],
      if (withUsage.isEmpty)
        _note(reports.isEmpty ? '没有在线的电脑。' : '在线的电脑没有提供用量。'),
    ]);
  }

  Widget _agentUsage(Map<String, dynamic> agent) {
    final theme = Theme.of(context);
    final value = agent['value'] as Map<String, dynamic>?;
    final windows = ((value?['windows'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final error = agent['error'] as String?;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _agentName(agent['name'] as String? ?? ''),
            style: theme.textTheme.titleSmall,
          ),
          if (windows.isEmpty)
            Text(
              error == null ? '暂无数据' : _usageError(error),
              style: theme.textTheme.bodySmall,
            ),
          for (final window in windows) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(child: Text(window['name'] as String? ?? '')),
                Text(
                  '${((window['usedPercent'] as num?) ?? 0).round()}%'
                  '${_since(window['resetsAt'], ' · 重置于 ')}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: (((window['usedPercent'] as num?) ?? 0) / 100).clamp(
                0.0,
                1.0,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );

  @override
  Widget build(BuildContext context) {
    final reports = _reports;
    return RefreshIndicator(
      onRefresh: _pullToRefresh,
      child: ListView(
        key: const Key('dashboard'),
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          _devices(),
          if (reports == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            _sessions(reports),
            _usage(reports),
          ],
        ],
      ),
    );
  }
}

String _title(Map<String, dynamic> session) {
  final title = session['title'] as String? ?? '';
  if (title.isNotEmpty) return title;
  return session['kind'] == 'shell' ? '终端' : '未命名';
}

String _agentName(String name) => switch (name) {
  'claude-code' => 'Claude Code',
  'codex' => 'Codex',
  'antigravity' => 'Antigravity',
  'copilot' => 'Copilot',
  'cursor' => 'Cursor',
  'grok' => 'Grok',
  'opencode' => 'OpenCode',
  'pi' => 'Pi',
  'trae' => 'Trae',
  _ => name,
};

String _usageError(String error) => switch (error) {
  'signIn' => '需要在电脑上登录',
  'keychainDenied' || 'keychainUnavailable' => '电脑的钥匙串无法读取',
  'claudeUnreachable' => '连不上 Claude',
  'codexNoAnswer' || 'antigravityNoAnswer' => '运行时没有回应',
  _ => '暂时无法读取',
};

/// [prefix] and a short local time for an RFC 3339 [at], or nothing.
String _since(Object? at, String prefix) {
  final time = DateTime.tryParse(at as String? ?? '')?.toLocal();
  if (time == null) return '';
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final clock = '${two(time.hour)}:${two(time.minute)}';
  final sameDay =
      time.year == now.year && time.month == now.month && time.day == now.day;
  return sameDay ? '$prefix$clock' : '$prefix${time.month}月${time.day}日 $clock';
}
