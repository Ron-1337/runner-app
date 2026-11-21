import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import '../core/core.dart';
import '../core/remote.dart';
import '../services.dart';

/// A live terminal of a session on the computer.
///
/// Opening it takes control of the terminal at this screen's size, as the desktop's
/// remote window does; the host desktop shows a card with Take back meanwhile.
/// After a reconnect it attaches again if no one else took the terminal meanwhile.
class TerminalPage extends StatefulWidget {
  const TerminalPage({
    super.key,
    required this.remote,
    required this.session,
    required this.title,
  });

  final Remote remote;
  final String session;
  final String title;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final _terminal = Terminal(maxLines: 10000);
  final _controller = TerminalController();
  StreamSubscription<RouteEvent>? _events;
  var _wasConnected = true;
  late final ByteConversionSink _decoder;

  (int, int)? _size;
  var _attached = false;
  var _inSnapshot = false;

  /// Who sets the terminal's size: `you`, `desktop`, `browser` or `none`.
  String _controllerKind = 'you';
  String? _ended;

  @override
  void initState() {
    super.initState();
    // Output arrives in chunks that can split a UTF-8 character.
    _decoder = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_TerminalSink(_terminal));
    _terminal.onOutput = _input;
    _terminal.onResize = (cols, rows, _, _) => _resized(cols, rows);
    _events = widget.remote.pushes.listen(_onEvent);
    widget.remote.addListener(_onState);
  }

  @override
  void dispose() {
    _events?.cancel();
    widget.remote.removeListener(_onState);
    if (_attached && _ended == null && widget.remote.connected) {
      _send({'type': 'detach', 'session': widget.session});
    }
    _controller.dispose();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    final size = _size;
    if (widget.remote.connected && !_wasConnected && size != null) {
      _attach(size, 'ifFree');
    }
    _wasConnected = widget.remote.connected;
  }

  bool get _live => _ended == null && widget.remote.connected;

  Future<void> _send(Map<String, Object?> message) async {
    try {
      await widget.remote.core.request(widget.remote.route, message);
    } catch (e) {
      if (mounted && _live) showError(context, e);
    }
  }

  void _attach((int, int) size, String control) {
    _send({
      'type': 'attach',
      'session': widget.session,
      'cols': size.$1,
      'rows': size.$2,
      'control': control,
      'history': 1000,
    });
  }

  void _resized(int cols, int rows) {
    _size = (cols, rows);
    if (!widget.remote.connected) return;
    if (!_attached) {
      _attached = true;
      _attach((cols, rows), 'take');
    } else if (_controllerKind == 'you') {
      _send({
        'type': 'viewport',
        'session': widget.session,
        'cols': cols,
        'rows': rows,
      });
    }
  }

  void _takeControl() {
    final size = _size;
    if (size == null) return;
    _send({
      'type': 'takeControl',
      'session': widget.session,
      'cols': size.$1,
      'rows': size.$2,
    });
  }

  void _input(String data) {
    if (!_live || _controllerKind != 'you') return;
    _send({
      'type': 'input',
      'session': widget.session,
      'data': base64Encode(utf8.encode(data)),
    });
  }

  void _onEvent(RouteEvent event) {
    final message = event.message!;
    if (message['session'] != widget.session) return;
    switch (event.type) {
      case 'snapshot':
        if (!_inSnapshot) {
          // A snapshot replaces the screen: on attach, and after the host resyncs.
          _terminal.write('\x1bc');
        }
        _inSnapshot = message['more'] == true;
        _decoder.add(base64Decode(message['data'] as String));
      case 'output':
        _decoder.add(base64Decode(message['data'] as String));
      case 'resized':
        final controller = message['controller'] as Map<String, dynamic>?;
        setState(
          () => _controllerKind = controller?['kind'] as String? ?? 'none',
        );
      case 'closed':
        setState(() => _ended = '会话已结束');
    }
  }

  @override
  Widget build(BuildContext context) {
    final reconnecting = _ended == null && !widget.remote.connected;
    final banner = reconnecting ? null : _ended ?? _controlBanner();
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: Column(
          children: [
            if (reconnecting) ReconnectBanner(remote: widget.remote),
            if (banner != null)
              MaterialBanner(
                content: Text(banner),
                actions: [
                  if (_ended == null)
                    TextButton(onPressed: _takeControl, child: const Text('接管'))
                  else
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('返回'),
                    ),
                ],
              ),
            Expanded(
              child: TerminalView(
                _terminal,
                controller: _controller,
                autofocus: true,
                readOnly: !_live || _controllerKind != 'you',
                deleteDetection: true,
                textStyle: const TerminalStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 13,
                ),
                keyboardType: TextInputType.text,
              ),
            ),
            if (_live) _KeyBar(terminal: _terminal),
          ],
        ),
      ),
    );
  }

  String? _controlBanner() => switch (_controllerKind) {
    'you' => null,
    'desktop' => '电脑桌面正在使用这个终端，只能查看。',
    'browser' => '另一台设备正在使用这个终端，只能查看。',
    _ => '没有人在控制这个终端。',
  };
}

class _TerminalSink implements Sink<String> {
  _TerminalSink(this.terminal);
  final Terminal terminal;

  @override
  void add(String data) => terminal.write(data);

  @override
  void close() {}
}

/// Keys a phone keyboard lacks. They go through the terminal so its modes apply.
class _KeyBar extends StatelessWidget {
  const _KeyBar({required this.terminal});

  final Terminal terminal;

  @override
  Widget build(BuildContext context) {
    Widget key(String label, VoidCallback onPressed) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 36),
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
        onPressed: onPressed,
        child: Text(label),
      ),
    );
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        children: [
          key('Esc', () => terminal.keyInput(TerminalKey.escape)),
          key('Tab', () => terminal.keyInput(TerminalKey.tab)),
          key('Ctrl+C', () => terminal.keyInput(TerminalKey.keyC, ctrl: true)),
          key('↑', () => terminal.keyInput(TerminalKey.arrowUp)),
          key('↓', () => terminal.keyInput(TerminalKey.arrowDown)),
          key('←', () => terminal.keyInput(TerminalKey.arrowLeft)),
          key('→', () => terminal.keyInput(TerminalKey.arrowRight)),
          key('Enter', () => terminal.keyInput(TerminalKey.enter)),
        ],
      ),
    );
  }
}
