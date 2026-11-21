import 'package:material_ui/material_ui.dart';

import '../core/core.dart';
import '../core/remote.dart';
import '../core/store.dart';
import '../services.dart';
import 'computer.dart';
import 'sign_in.dart';

/// Every account's computers, as runner-server lists them to this phone,
/// grouped by account.
class ComputersPage extends StatefulWidget {
  const ComputersPage({super.key});

  @override
  State<ComputersPage> createState() => _ComputersPageState();
}

class _ComputersPageState extends State<ComputersPage> {
  List<Account>? _accounts;
  final _computers = <String, List<Map<String, dynamic>>>{};
  final _errors = <String, String>{};

  /// `<account id>/<computer id>` while that computer is connecting.
  String? _opening;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_accounts == null) _load();
  }

  Future<void> _load() async {
    final services = Services.of(context);
    final accounts = await services.store.accounts();
    if (!mounted) return;
    if (accounts.isEmpty) {
      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const ServerPage()),
        (_) => false,
      );
      return;
    }
    setState(() => _accounts = accounts);
    await Future.wait(accounts.map(_loadAccount));
  }

  Future<void> _loadAccount(Account account) async {
    try {
      final hosts = await listComputers(Services.of(context).core, account);
      if (!mounted) return;
      setState(() {
        _computers[account.id] = hosts;
        _errors.remove(account.id);
      });
    } catch (e) {
      if (mounted) setState(() => _errors[account.id] = e.toString());
    }
  }

  Future<void> _addAccount([String? origin]) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => ServerPage(initialOrigin: origin)),
  );

  Future<void> _signOut(Account account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('退出登录'),
        content: Text('退出 ${account.label}？这个账户下的电脑配对也会一并删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final services = Services.of(context);
    try {
      await services.core.call('signOut', {
        'origin': account.origin,
        'credential': account.credential,
      });
    } catch (_) {
      // Signed out on the server already, or unreachable: forget it locally anyway.
    }
    await services.store.removeAccount(account);
    _computers.remove(account.id);
    _errors.remove(account.id);
    if (mounted) await _load();
  }

  Future<void> _open(Account account, Map<String, dynamic> computer) async {
    setState(() => _opening = '${account.id}/${computer['id']}');
    final connected = await openComputer(
      context,
      account,
      computer,
      onConnected: () {
        if (mounted) setState(() => _opening = null);
      },
    );
    if (!mounted) return;
    setState(() => _opening = null);
    if (connected) await _loadAccount(account);
  }

  Future<void> _refresh() async {
    _accounts = null;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _accounts;
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的电脑'),
        actions: [
          IconButton(
            key: const Key('addAccount'),
            tooltip: '添加账户',
            icon: const Icon(Icons.person_add_alt),
            onPressed: _addAccount,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: [
            if (accounts == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
            for (final account in accounts ?? const <Account>[])
              ..._section(account),
          ],
        ),
      ),
    );
  }

  List<Widget> _section(Account account) {
    final computers = _computers[account.id];
    final error = _errors[account.id];
    return [
      _AccountHeader(
        account: account,
        onSignInAgain: () => _addAccount(account.origin),
        onSignOut: () => _signOut(account),
      ),
      if (error != null)
        ListTile(
          leading: const Icon(Icons.error_outline),
          title: Text(error),
          subtitle: const Text('下拉重试，或在右侧菜单中重新登录'),
        )
      else if (computers == null)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (computers.isEmpty)
        ListTile(
          title: const Text('还没有电脑'),
          subtitle: Text(
            '在电脑上运行 runner remote login --server ${account.origin} 登录到同一个账号。',
          ),
        ),
      for (final computer in computers ?? const <Map<String, dynamic>>[])
        _ComputerTile(
          computer: computer,
          opening: _opening == '${account.id}/${computer['id']}',
          onTap: _opening == null && computer['online'] == true
              ? () => _open(account, computer)
              : null,
        ),
    ];
  }
}

class _AccountHeader extends StatelessWidget {
  const _AccountHeader({
    required this.account,
    required this.onSignInAgain,
    required this.onSignOut,
  });

  final Account account;
  final VoidCallback onSignInAgain;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      leading: const Icon(Icons.account_circle_outlined),
      title: Text(
        account.label,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
      trailing: PopupMenuButton<String>(
        key: Key('account.${account.id}'),
        onSelected: (action) =>
            action == 'signInAgain' ? onSignInAgain() : onSignOut(),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'signInAgain', child: Text('重新登录')),
          PopupMenuItem(value: 'signOut', child: Text('退出登录')),
        ],
      ),
    );
  }
}

/// The computers runner-server lists under [account].
Future<List<Map<String, dynamic>>> listComputers(
  Core core,
  Account account,
) async {
  final result =
      await core.call('listComputers', {
            'origin': account.origin,
            'credential': account.credential,
          })
          as Map<String, dynamic>;
  return (result['hosts'] as List).cast<Map<String, dynamic>>();
}

/// Connects to [computer] under [account], pairing by PIN first when this
/// phone has no keys for it, and shows it until the person leaves.
///
/// [onConnected] runs once the route is open, before the computer's page shows.
/// Completes with whether the computer's page was shown.
Future<bool> openComputer(
  BuildContext context,
  Account account,
  Map<String, dynamic> computer, {
  VoidCallback? onConnected,
  String? session,
}) async {
  final id = computer['id'] as String;
  final services = Services.of(context);
  final route = {
    'origin': account.origin,
    'credential': account.credential,
    'computer': id,
  };
  try {
    var saved = await services.store.pairing(account, id);
    Future<Map<String, dynamic>> connect(Pairing pairing) async =>
        await services.core.call('connect', {
              ...route,
              'clientKey': pairing.clientKey,
              'hostKey': pairing.hostKey,
            })
            as Map<String, dynamic>;
    final Map<String, dynamic> opened;
    if (saved != null && saved.fingerprint == computer['fingerprint']) {
      opened = await connect(saved);
    } else {
      if (!context.mounted) return false;
      final pin = await askPin(context, computer);
      if (pin == null) return false;
      opened =
          await services.core.call('pair', {
                ...route,
                'fingerprint': computer['fingerprint'],
                'pin': pin,
                'name': deviceName(),
              })
              as Map<String, dynamic>;
      saved = Pairing(
        clientKey: opened['clientKey'] as String,
        hostKey: opened['hostKey'] as String,
        fingerprint: computer['fingerprint'] as String,
      );
      await services.store.savePairing(account, id, saved);
    }
    final pairing = saved;
    onConnected?.call();
    if (!context.mounted) {
      await services.core.call('close', {'route': opened['route']});
      return false;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComputerPage(
          account: account,
          computer: computer,
          session: session,
          remote: Remote(
            core: services.core,
            route: opened['route'] as int,
            welcome: opened['welcome'] as Map<String, dynamic>,
            open: () => connect(pairing),
          ),
        ),
      ),
    );
    return true;
  } on CoreException catch (e) {
    if (!context.mounted) return false;
    if (e.message.contains('不认识本机')) {
      return _offerRepair(context, account, computer, e.message);
    }
    showError(context, e);
    return false;
  }
}

/// Opens the computer with id [computerId] under [account], looking it up first,
/// and then [session] on it when given; how links and notifications open one.
Future<bool> openComputerById(
  BuildContext context,
  Account account,
  String computerId, {
  String? session,
}) async {
  final List<Map<String, dynamic>> computers;
  try {
    computers = await listComputers(Services.of(context).core, account);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
  if (!context.mounted) return false;
  final computer = computers.where((c) => c['id'] == computerId).firstOrNull;
  if (computer == null) {
    showError(context, '${account.label} 下找不到这台电脑');
    return false;
  }
  if (computer['online'] != true) {
    showError(context, '${computer['name']} 不在线');
    return false;
  }
  return openComputer(context, account, computer, session: session);
}

Future<bool> _offerRepair(
  BuildContext context,
  Account account,
  Map<String, dynamic> computer,
  String message,
) async {
  final repair = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('需要重新配对'),
      content: Text('$message\n\n电脑指纹：${computer['fingerprint']}'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, true),
          child: const Text('重新配对'),
        ),
      ],
    ),
  );
  if (repair != true || !context.mounted) return false;
  final store = Services.of(context).store;
  await store.forgetPairing(account, computer['id'] as String);
  if (!context.mounted) return false;
  return openComputer(context, account, computer);
}

class _ComputerTile extends StatelessWidget {
  const _ComputerTile({
    required this.computer,
    required this.opening,
    required this.onTap,
  });

  final Map<String, dynamic> computer;
  final bool opening;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final online = computer['online'] == true;
    final info = (computer['info'] as Map<String, dynamic>?) ?? const {};
    final platform = [
      info['platform'],
      info['osVersion'],
    ].whereType<String>().where((s) => s.isNotEmpty).join(' ');
    return ListTile(
      leading: Icon(
        Icons.computer,
        color: online
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).disabledColor,
      ),
      title: Text(computer['name'] as String? ?? ''),
      subtitle: Text(
        [online ? '在线' : '离线', if (platform.isNotEmpty) platform].join(' · '),
      ),
      trailing: opening
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// Asks for the six-digit PIN set on the computer with `runner remote pin`.
Future<String?> askPin(BuildContext context, Map<String, dynamic> computer) {
  final pin = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('与 ${computer['name']} 配对'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('输入这台电脑的 6 位 PIN（在电脑上用 runner remote pin 设置）。'),
          const SizedBox(height: 8),
          Text(
            '指纹：${computer['fingerprint']}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
          TextField(
            key: const Key('pin'),
            controller: pin,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(labelText: 'PIN'),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, pin.text),
          child: const Text('配对'),
        ),
      ],
    ),
  );
}
