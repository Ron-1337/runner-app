import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/links.dart';
import '../services.dart';
import 'computers.dart';

export '../core/links.dart' show validateOrigin;

/// The runner-server origin to sign in to: the first screen, and how another
/// account is added.
class ServerPage extends StatefulWidget {
  const ServerPage({super.key, this.initialOrigin, this.notice});

  /// Fills in the address, from a link or to sign in again.
  final String? initialOrigin;

  /// Why signing in is asked for, shown above the address.
  final String? notice;

  @override
  State<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends State<ServerPage> {
  late final _origin = TextEditingController(text: widget.initialOrigin);
  // Filled at once with the name known so far, then with the model once
  // deviceInfo has it, unless the person has typed a name meanwhile.
  late final _initialName = deviceName();
  late final _name = TextEditingController(text: _initialName);
  String? _error;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    deviceInfo().then((device) {
      final model = device['name'] as String?;
      if (mounted && model != null && _name.text == _initialName) {
        _name.text = model;
      }
    });
  }

  @override
  void dispose() {
    _origin.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final error = validateOrigin(_origin.text);
    setState(() => _error = error);
    if (error != null) return;
    final origin = _origin.text.trim();
    if (isPlainHttp(origin) && !await confirmPlainHttp(context, origin)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final core = Services.of(context).core;
      // Signing in does not wait for the plugins; what they found so far is used.
      final device = {...knownDeviceInfo()};
      final name = cleanDeviceName(_name.text);
      if (name.isNotEmpty) device['name'] = name;
      final start = await core.call('startEnrollment', {
        'origin': origin,
        'device': device,
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
    final adding = Navigator.canPop(context);
    return Scaffold(
      appBar: AppBar(title: Text(adding ? '添加账户' : 'Runner Remote')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.notice != null) ...[
              Text(widget.notice!),
              const SizedBox(height: 16),
            ],
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
            TextField(
              key: const Key('deviceName'),
              controller: _name,
              maxLength: 64,
              decoration: const InputDecoration(
                labelText: '设备名称',
                helperText: '批准登录时和电脑上会显示这个名字',
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

/// Asks before signing in over unencrypted HTTP. Continuing is held back for a
/// second, so the warning is not tapped away unread.
Future<bool> confirmPlainHttp(BuildContext context, String origin) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _PlainHttpDialog(origin: origin),
    ) ==
    true;

class _PlainHttpDialog extends StatefulWidget {
  const _PlainHttpDialog({required this.origin});
  final String origin;

  @override
  State<_PlainHttpDialog> createState() => _PlainHttpDialogState();
}

class _PlainHttpDialogState extends State<_PlainHttpDialog> {
  static const _hold = Duration(seconds: 1);
  late final Timer _timer;
  var _ready = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_hold, () {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.lock_open),
    title: const Text('连接未加密'),
    content: Text(
      '${widget.origin} 使用 HTTP，登录时的账号、密码和登录凭据会以明文在网络上传输，'
      '同一网络中的其他人可能看到或篡改。电脑与手机之间的会话内容仍然端到端加密。\n\n'
      '只在可信的网络（例如家里或公司内网）中继续。',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('httpProceed'),
        onPressed: _ready ? () => Navigator.pop(context, true) : null,
        child: Text(_ready ? '继续' : '继续（1 秒）'),
      ),
    ],
  );
}

/// The URL scheme the sign-in browser returns to once the server has a
/// decision; runner-server redirects there when the page was opened with
/// `app=1`.
const authCallbackScheme = 'runner-remote-auth';

/// Opens [url] in the system's sign-in browser (Custom Tabs on Android,
/// ASWebAuthenticationSession on iOS), which shares the browser's sign-in.
/// Completes once the page returns to the app; throws when the person closes
/// it first. Tests replace it.
Future<void> Function(String url) openSignInBrowser = (url) =>
    FlutterWebAuth2.authenticate(
      url: url,
      callbackUrlScheme: authCallbackScheme,
    );

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
    // Straight to the approval page, as signing in with a web account does.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _open();
    });
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
          await services.store.addAccount(
            origin: widget.origin,
            credential: result['credential'] as String,
            username:
                (result['account'] as Map<String, dynamic>?)?['username']
                    as String? ??
                '',
          );
          if (!mounted) return;
          await Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute<void>(builder: (_) => const ComputersPage()),
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

  /// The approval page, marked so runner-server sends the browser back here.
  String get _appLink {
    final uri = Uri.parse(_link);
    return uri
        .replace(queryParameters: {...uri.queryParameters, 'app': '1'})
        .toString();
  }

  Future<void> _open() async {
    try {
      await openSignInBrowser(_appLink);
      // Returned with a decision: ask at once rather than at the next tick.
      if (mounted) await _poll();
    } on PlatformException catch (e) {
      // Closed by the person, or a server that does not return to the app:
      // polling carries on either way.
      if (e.code == 'CANCELED') return;
      await _openExternally();
    } on MissingPluginException {
      await _openExternally();
    }
  }

  Future<void> _openExternally() async {
    if (!mounted) return;
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(_link),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
    if (!opened && mounted) showError(context, '无法打开浏览器，请手动访问：$_link');
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
