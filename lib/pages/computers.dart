import 'package:material_ui/material_ui.dart';

import '../core/core.dart';
import '../core/remote.dart';
import '../core/store.dart';
import '../services.dart';
import 'computer.dart';
import 'sign_in.dart';

/// The account's computers, as runner-server lists them to this phone.
class ComputersPage extends StatefulWidget {
  const ComputersPage({super.key, required this.account});

  final Account account;

  @override
  State<ComputersPage> createState() => _ComputersPageState();
}

class _ComputersPageState extends State<ComputersPage> {
  List<Map<String, dynamic>>? _computers;
  String? _error;
  String? _opening;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_computers == null && _error == null) _load();
  }

  Future<void> _load() async {
    try {
      final result =
          await Services.of(context).core.call('listComputers', {
                'origin': widget.account.origin,
                'credential': widget.account.credential,
              })
              as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _computers = (result['hosts'] as List).cast<Map<String, dynamic>>();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _signOut() async {
    final services = Services.of(context);
    try {
      await services.core.call('signOut', {
        'origin': widget.account.origin,
        'credential': widget.account.credential,
      });
    } catch (_) {
      // Signed out on the server already, or unreachable: forget it locally anyway.
    }
    await services.store.signOut();
    if (!mounted) return;
    await Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const ServerPage()),
      (_) => false,
    );
  }

  Future<void> _open(Map<String, dynamic> computer) async {
    final id = computer['id'] as String;
    final services = Services.of(context);
    setState(() => _opening = id);
    try {
      var saved = await services.store.pairing(id);
      Future<Map<String, dynamic>> connect(Pairing pairing) async =>
          await services.core.call('connect', {
                ..._route(id),
                'clientKey': pairing.clientKey,
                'hostKey': pairing.hostKey,
              })
              as Map<String, dynamic>;
      final Map<String, dynamic> opened;
      if (saved != null && saved.fingerprint == computer['fingerprint']) {
        opened = await connect(saved);
      } else {
        if (!mounted) return;
        final pin = await askPin(context, computer);
        if (pin == null) return;
        opened =
            await services.core.call('pair', {
                  ..._route(id),
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
        await services.store.savePairing(id, saved);
      }
      final pairing = saved;
      if (!mounted) return;
      setState(() => _opening = null);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ComputerPage(
            account: widget.account,
            computer: computer,
            remote: Remote(
              core: services.core,
              route: opened['route'] as int,
              welcome: opened['welcome'] as Map<String, dynamic>,
              open: () => connect(pairing),
            ),
          ),
        ),
      );
      if (mounted) _load();
    } on CoreException catch (e) {
      if (!mounted) return;
      if (e.message.contains('不认识本机')) {
        await _offerRepair(computer, e.message);
      } else {
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Map<String, Object?> _route(String computer) => {
    'origin': widget.account.origin,
    'credential': widget.account.credential,
    'computer': computer,
  };

  Future<void> _offerRepair(
    Map<String, dynamic> computer,
    String message,
  ) async {
    final repair = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('需要重新配对'),
        content: Text('$message\n\n电脑指纹：${computer['fingerprint']}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重新配对'),
          ),
        ],
      ),
    );
    if (repair != true || !mounted) return;
    await Services.of(context).store.forgetPairing(computer['id'] as String);
    if (mounted) await _open(computer);
  }

  @override
  Widget build(BuildContext context) {
    final computers = _computers;
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的电脑'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (_) => _signOut(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'signOut',
                child: Text('退出登录（${widget.account.username}）'),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            if (_error != null)
              ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(_error!),
                subtitle: const Text('下拉重试'),
              )
            else if (computers == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (computers.isEmpty)
              const ListTile(
                title: Text('还没有电脑'),
                subtitle: Text(
                  '在电脑上运行 runner remote login --server <服务器地址> 登录到同一个账号。',
                ),
              ),
            for (final computer in computers ?? const <Map<String, dynamic>>[])
              _ComputerTile(
                computer: computer,
                opening: _opening == computer['id'],
                onTap: _opening == null && computer['online'] == true
                    ? () => _open(computer)
                    : null,
              ),
          ],
        ),
      ),
    );
  }
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
