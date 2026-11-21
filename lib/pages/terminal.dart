import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import '../core/core.dart';
import '../core/mouse.dart';
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
    this.runtime,
  });

  final Remote remote;
  final String session;
  final String title;

  /// The agent runtime of the session (such as `claude-code`); null for a shell.
  final String? runtime;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final _mouse = MouseModes();
  late final _terminal = Terminal(
    maxLines: 10000,
    mouseHandler: TrackedMouseHandler(_mouse),
  );
  final _controller = TerminalController();
  final _focus = FocusNode();
  double _fontSize = defaultFontSize;
  var _loadedFontSize = false;
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
    ).startChunkedConversion(_TerminalSink(_terminal, _mouse));
    _terminal.onOutput = _input;
    _terminal.onResize = (cols, rows, _, _) => _resized(cols, rows);
    _events = widget.remote.pushes.listen(_onEvent);
    widget.remote.addListener(_onState);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedFontSize) return;
    _loadedFontSize = true;
    Services.of(context).store.terminalFontSize().then((size) {
      if (mounted && size != null) setState(() => _fontSize = size);
    });
  }

  void _setFontSize(double size) {
    setState(() => _fontSize = size);
    Services.of(context).store.setTerminalFontSize(size);
  }

  /// Types [command] into the agent and submits it, as the person would.
  Future<void> _command(String command) async {
    _input(command);
    // Sent apart, so the agent sees a keypress rather than a pasted newline.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _input('\r');
    if (mounted) showMessage(context, '已发送 $command');
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => TerminalSettings(
        remote: widget.remote,
        runtime: widget.runtime,
        fontSize: _fontSize,
        onFontSize: _setFontSize,
        canType: _live && _controllerKind == 'you',
        onCommand: _command,
      ),
    );
  }

  @override
  void dispose() {
    _events?.cancel();
    widget.remote.removeListener(_onState);
    if (_attached && _ended == null && widget.remote.connected) {
      _send({'type': 'detach', 'session': widget.session});
    }
    _controller.dispose();
    _focus.dispose();
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
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            key: const Key('terminalSettings'),
            tooltip: '设置',
            icon: const Icon(Icons.tune),
            onPressed: _showSettings,
          ),
        ],
      ),
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
                focusNode: _focus,
                autofocus: true,
                readOnly: !_live || _controllerKind != 'you',
                deleteDetection: true,
                textStyle: TerminalStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: _fontSize,
                ),
                keyboardType: TextInputType.text,
              ),
            ),
            if (_live)
              _KeyBar(terminal: _terminal, onHideKeyboard: _focus.unfocus),
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
  _TerminalSink(this.terminal, this.mouse);
  final Terminal terminal;
  final MouseModes mouse;

  @override
  void add(String data) {
    mouse.scan(data);
    terminal.write(data);
  }

  @override
  void close() {}
}

/// Keys a phone keyboard lacks. They go through the terminal so its modes apply.
class _KeyBar extends StatelessWidget {
  const _KeyBar({required this.terminal, required this.onHideKeyboard});

  final Terminal terminal;
  final VoidCallback onHideKeyboard;

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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: IconButton.outlined(
              key: const Key('hideKeyboard'),
              tooltip: '收起键盘',
              constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.keyboard_hide_outlined, size: 20),
              onPressed: onHideKeyboard,
            ),
          ),
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

const defaultFontSize = 13.0;
const minFontSize = 8.0;
const maxFontSize = 28.0;

/// The command that switches [runtime]'s model or effort in a running session,
/// or null when it has none that takes the value directly.
String? switchCommand(String? runtime, String setting, String value) {
  if (runtime != 'claude-code' && runtime != 'claude') return null;
  return '/$setting $value';
}

/// The terminal's font size, and the agent's model and effort.
///
/// No request changes a running session's model, so the choice is typed into
/// the agent as its own slash command; only Claude Code takes one with the
/// value. The catalog lists what the computer offers for the runtime.
class TerminalSettings extends StatefulWidget {
  const TerminalSettings({
    super.key,
    required this.remote,
    required this.runtime,
    required this.fontSize,
    required this.onFontSize,
    required this.canType,
    required this.onCommand,
  });

  final Remote remote;
  final String? runtime;
  final double fontSize;
  final ValueChanged<double> onFontSize;
  final bool canType;
  final ValueChanged<String> onCommand;

  @override
  State<TerminalSettings> createState() => _TerminalSettingsState();
}

class _TerminalSettingsState extends State<TerminalSettings> {
  late double _fontSize = widget.fontSize;
  Map<String, dynamic>? _runtime;
  String? _error;
  var _loading = false;

  bool get _switchable => switchCommand(widget.runtime, 'model', '') != null;

  @override
  void initState() {
    super.initState();
    if (_switchable && widget.remote.has('catalog')) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final catalog = await widget.remote.catalog();
      final runtimes = ((catalog['runtimes'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(
        () => _runtime = runtimes
            .where((r) => r['name'] == widget.runtime)
            .firstOrNull,
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _font(double size) {
    final clamped = size.clamp(minFontSize, maxFontSize).toDouble();
    setState(() => _fontSize = clamped);
    widget.onFontSize(clamped);
  }

  List<Map<String, dynamic>> _options(String key) =>
      ((_runtime?[key] as List?) ?? const []).cast<Map<String, dynamic>>();

  Widget _choices(String title, String setting, String key) {
    final options = _options(key);
    if (options.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in options)
                ActionChip(
                  key: Key('$setting-${option['value']}'),
                  label: Text(
                    option['label'] as String? ?? option['value'] as String,
                  ),
                  onPressed: widget.canType
                      ? () {
                          Navigator.pop(context);
                          widget.onCommand(
                            switchCommand(
                              widget.runtime,
                              setting,
                              option['value'] as String,
                            )!,
                          );
                        }
                      : null,
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String? note;
    if (widget.runtime == null) {
      note = null;
    } else if (!_switchable) {
      note = '这个运行时不支持在手机上切换模型和 effort。';
    } else if (!widget.canType) {
      note = '接管终端后才能切换模型和 effort。';
    } else if (_error != null) {
      note = _error;
    } else if (!_loading && _runtime == null) {
      note = '电脑没有提供这个运行时的模型列表。';
    }
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: const Text('字体大小'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const Key('fontSmaller'),
                    tooltip: '缩小',
                    icon: const Icon(Icons.text_decrease),
                    onPressed: _fontSize > minFontSize
                        ? () => _font(_fontSize - 1)
                        : null,
                  ),
                  SizedBox(
                    width: 32,
                    child: Text(
                      _fontSize.round().toString(),
                      key: const Key('fontSize'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  IconButton(
                    key: const Key('fontLarger'),
                    tooltip: '放大',
                    icon: const Icon(Icons.text_increase),
                    onPressed: _fontSize < maxFontSize
                        ? () => _font(_fontSize + 1)
                        : null,
                  ),
                ],
              ),
            ),
            if (_fontSize != defaultFontSize)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: () => _font(defaultFontSize),
                  child: const Text('恢复默认'),
                ),
              ),
            if (widget.runtime != null) const Divider(),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            _choices('模型', 'model', 'models'),
            _choices('Effort', 'effort', 'efforts'),
            if (note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(note, style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}
