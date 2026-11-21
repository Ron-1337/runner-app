import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/store.dart';
import '../services.dart';
import 'computers.dart';

/// Mirrors Runner's rule: HTTPS only, except plain HTTP on localhost for testing.
String? validateOrigin(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || uri.host.isEmpty) {
    return '请输入完整地址，例如 https://runner.example.com';
  }
  if (uri.scheme == 'https') return null;
  if (uri.scheme == 'http' &&
      (uri.host == 'localhost' || uri.host == '127.0.0.1')) {
    return null;
  }
  return '只支持 HTTPS 地址';
}

/// First screen: the runner-server origin to sign in to.
class ServerPage extends StatefulWidget {
  const ServerPage({super.key});

  @override
  State<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends State<ServerPage> {
  final _origin = TextEditingController();
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    _origin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final error = validateOrigin(_origin.text);
    setState(() => _error = error);
    if (error != null) return;
    final origin = _origin.text.trim();
    setState(() => _busy = true);
    try {
      final start = await Services.of(context).core.call('startEnrollment', {
        'origin': origin,
        'device': deviceInfo(),
      });
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              EnrollPage(origin: origin, start: start as Map<String, dynamic>),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Runner Remote')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('origin'),
              controller: _origin,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: '服务器地址',
                hintText: 'https://runner.example.com',
                errorText: _error,
                errorMaxLines: 3,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('登录'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the sign-in code and waits while the person approves it in a browser.
class EnrollPage extends StatefulWidget {
  const EnrollPage({super.key, required this.origin, required this.start});

  final String origin;
  final Map<String, dynamic> start;

  @override
  State<EnrollPage> createState() => _EnrollPageState();
}

class _EnrollPageState extends State<EnrollPage> {
  Timer? _timer;
  String? _problem;
  var _polling = false;

  String get _code => widget.start['userCode'] as String;
  String get _link => widget.start['verificationUriComplete'] as String;

  @override
  void initState() {
    super.initState();
    final interval = (widget.start['interval'] as num?)?.toInt() ?? 5;
    _timer = Timer.periodic(
      Duration(seconds: interval.clamp(1, 30)),
      (_) => _poll(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final services = Services.of(context);
      final result =
          await services.core.call('pollEnrollment', {
                'origin': widget.origin,
                'deviceCode': widget.start['deviceCode'],
              })
              as Map<String, dynamic>;
      if (!mounted) return;
      switch (result['state']) {
        case 'ENROLLMENT_STATE_APPROVED':
          _timer?.cancel();
          final account = Account(
            origin: widget.origin,
            credential: result['credential'] as String,
            username:
                (result['account'] as Map<String, dynamic>?)?['username']
                    as String? ??
                '',
          );
          await services.store.saveAccount(account);
          if (!mounted) return;
          await Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute<void>(
              builder: (_) => ComputersPage(account: account),
            ),
            (_) => false,
          );
        case 'ENROLLMENT_STATE_DENIED':
          _timer?.cancel();
          setState(() => _problem = '登录请求被拒绝了。');
        case 'ENROLLMENT_STATE_EXPIRED':
          _timer?.cancel();
          setState(() => _problem = '代码已过期，请返回重新登录。');
      }
    } catch (e) {
      if (mounted) setState(() => _problem = e.toString());
    } finally {
      _polling = false;
    }
  }

  Future<void> _open() async {
    if (!await launchUrl(
      Uri.parse(_link),
      mode: LaunchMode.externalApplication,
    )) {
      if (mounted) showError(context, '无法打开浏览器，请手动访问：$_link');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('批准登录')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('在浏览器中登录服务器并批准这部手机，核对代码与下面显示的一致：'),
          const SizedBox(height: 24),
          SelectableText(
            _code,
            key: const Key('userCode'),
            textAlign: TextAlign.center,
            style: theme.textTheme.displaySmall?.copyWith(
              fontFamily: 'monospace',
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _open,
            icon: const Icon(Icons.open_in_browser),
            label: const Text('打开批准页面'),
          ),
          const SizedBox(height: 8),
          SelectableText(
            _link,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 32),
          if (_problem == null)
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 12),
                Text('等待批准…'),
              ],
            )
          else
            Text(
              _problem!,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.error),
            ),
        ],
      ),
    );
  }
}
