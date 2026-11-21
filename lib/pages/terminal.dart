import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import '../core/core.dart';
import '../core/modifiers.dart';
import '../core/mouse.dart';
import '../core/remote.dart';
import '../core/sgr.dart';
import '../services.dart';
import 'terminal_keyboard.dart';

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
  final _keyboard = GlobalKey<TerminalKeyboardState>();

  /// What the phone keyboard is composing (pinyin and the like), shown above
  /// the key bar until it is committed.
  String? _composing;
  double _fontSize = defaultFontSize;
  var _loadedFontSize = false;

  /// Whether the phone keyboard's return key sends; otherwise it starts a new
  /// line (Ctrl+J, which Claude Code and shells both take that way).
  var _enterSends = false;

  /// Held for the next key: on the key bar, then cleared once a key uses them.
  var _ctrl = false;
  var _alt = false;
  var _shift = false;

  /// The model and effort last chosen here, shown when the settings reopen.
  String? _model;
  String? _effort;
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
    _focus.addListener(_onFocus);
  }

  void _onFocus() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedFontSize) return;
    _loadedFontSize = true;
    final store = Services.of(context).store;
    store.terminalFontSize().then((size) {
      if (mounted && size != null) setState(() => _fontSize = size);
    });
    store.keyboardEnterSends().then((sends) => _enterSends = sends);
  }

  void _setFontSize(double size) {
    setState(() => _fontSize = size);
    Services.of(context).store.setTerminalFontSize(size);
  }

  /// Types [command] into the agent and submits it, as the person would.
  Future<void> _command(String command) async {
    _type(command);
    // Sent apart, so the agent sees a keypress rather than a pasted newline.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _type('\r');
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
        model: _model,
        effort: _effort,
        onModel: (model) {
          _model = model;
          _command(switchCommand(widget.runtime, 'model', model)!);
        },
        onEffort: (effort) {
          _effort = effort;
          _command(switchCommand(widget.runtime, 'effort', effort)!);
        },
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

  /// What the terminal sends: keys, the keyboard's text and mouse reports.
  /// The held modifiers apply to the next single key.
  void _input(String data) {
    if ((_ctrl || _alt || _shift) && data.runes.length == 1) {
      data = applyModifiers(data, ctrl: _ctrl, alt: _alt, shift: _shift);
      _clearModifiers();
    }
    _type(data);
  }

  void _clearModifiers() {
    if (!_ctrl && !_alt && !_shift) return;
    setState(() => _ctrl = _alt = _shift = false);
  }

  /// A key-bar key, with the held modifiers.
  void _key(TerminalKey key) {
    final (ctrl, alt, shift) = (_ctrl, _alt, _shift);
    _clearModifiers();
    _terminal.keyInput(key, ctrl: ctrl, alt: alt, shift: shift);
  }

  void _type(String data) {
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
    // Read first, so the page rebuilds when the keyboard comes and goes.
    final keyboardOpen =
        MediaQuery.viewInsetsOf(context).bottom > 0 && _focus.hasFocus;
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
              child: TerminalKeyboard(
                key: _keyboard,
                focusNode: _focus,
                readOnly: !_live || _controllerKind != 'you',
                onText: _terminal.textInput,
                onBackspace: () => _terminal.keyInput(TerminalKey.backspace),
                // The key bar's Enter always sends.
                onEnter: () => _enterSends
                    ? _terminal.keyInput(TerminalKey.enter)
                    : _type('\n'),
                onComposing: (text) {
                  if (text != _composing && mounted) {
                    setState(() => _composing = text);
                  }
                },
                // The phone keyboard goes through TerminalKeyboard; the view
                // keeps only a hardware keyboard's keys.
                child: TerminalView(
                  _terminal,
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  hardwareKeyboardOnly: true,
                  readOnly: !_live || _controllerKind != 'you',
                  textStyle: TerminalStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: _fontSize,
                  ),
                ),
              ),
            ),
            if (_composing != null && _composing!.isNotEmpty)
              Container(
                key: const Key('composing'),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Text(_composing!),
              ),
            if (_live)
              _KeyBar(
                onKey: _key,
                keyboardOpen: keyboardOpen,
                onHideKeyboard: _focus.unfocus,
                onShowKeyboard: () => _keyboard.currentState?.show(),
                ctrl: _ctrl,
                alt: _alt,
                shift: _shift,
                onCtrl: () => setState(() => _ctrl = !_ctrl),
                onAlt: () => setState(() => _alt = !_alt),
                onShift: () => setState(() => _shift = !_shift),
              ),
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
  final _styles = SgrFilter();

  @override
  void add(String data) {
    final text = _styles.apply(data);
    mouse.scan(text);
    terminal.write(text);
  }

  @override
  void close() {}
}

/// Keys a phone keyboard lacks. They go through the terminal so its modes apply.
///
/// Ctrl, Alt and Shift stay held for one key, from this bar or the keyboard,
/// and combine.
class _KeyBar extends StatelessWidget {
  const _KeyBar({
    required this.onKey,
    required this.keyboardOpen,
    required this.onHideKeyboard,
    required this.onShowKeyboard,
    required this.ctrl,
    required this.alt,
    required this.shift,
    required this.onCtrl,
    required this.onAlt,
    required this.onShift,
  });

  final ValueChanged<TerminalKey> onKey;
  final bool keyboardOpen;
  final VoidCallback onHideKeyboard;
  final VoidCallback onShowKeyboard;
  final bool ctrl;
  final bool alt;
  final bool shift;
  final VoidCallback onCtrl;
  final VoidCallback onAlt;
  final VoidCallback onShift;

  @override
  Widget build(BuildContext context) {
    final style = OutlinedButton.styleFrom(
      minimumSize: const Size(44, 36),
      padding: const EdgeInsets.symmetric(horizontal: 10),
    );
    Widget pad(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: child,
    );
    Widget key(String label, TerminalKey key) => pad(
      OutlinedButton(
        style: style,
        onPressed: () => onKey(key),
        child: Text(label),
      ),
    );
    Widget modifier(String label, bool held, VoidCallback onPressed) => pad(
      held
          ? FilledButton(
              key: Key('modifier-$label'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(44, 36),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: onPressed,
              child: Text(label),
            )
          : OutlinedButton(
              key: Key('modifier-$label'),
              style: style,
              onPressed: onPressed,
              child: Text(label),
            ),
    );
    // The keyboard button and Enter stay put; the keys between them scroll.
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            pad(
              IconButton.outlined(
                key: const Key('keyboard'),
                tooltip: keyboardOpen ? '收起键盘' : '打开键盘',
                constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
                padding: EdgeInsets.zero,
                icon: Icon(
                  keyboardOpen
                      ? Icons.keyboard_hide_outlined
                      : Icons.keyboard_outlined,
                  size: 20,
                ),
                onPressed: keyboardOpen ? onHideKeyboard : onShowKeyboard,
              ),
            ),
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  key('Esc', TerminalKey.escape),
                  key('Tab', TerminalKey.tab),
                  modifier('Ctrl', ctrl, onCtrl),
                  modifier('Shift', shift, onShift),
                  modifier('Alt', alt, onAlt),
                  key('↑', TerminalKey.arrowUp),
                  key('↓', TerminalKey.arrowDown),
                  key('←', TerminalKey.arrowLeft),
                  key('→', TerminalKey.arrowRight),
                ],
              ),
            ),
            key('Enter', TerminalKey.enter),
          ],
        ),
      ),
    );
  }
}

const defaultFontSize = 13.0;

/// The effort slider's track inset; the stop labels line up with it.
const _sliderInset = 24.0;

/// An effort level's Chinese name, shown under its stop.
String effortHint(String effort) => switch (effort) {
  'none' => '不思考',
  'minimal' => '最低',
  'low' => '低',
  'medium' => '中',
  'high' => '高',
  'xhigh' => '超高',
  'max' => '最高',
  _ => '',
};
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
/// No request changes a running session's model, so a choice is typed into
/// the agent as its own slash command; only Claude Code takes one with the
/// value. The catalog lists what the computer offers for the runtime. The
/// agent does not say which model it runs, so the choice shown is the last one
/// made here, or the runtime's default.
class TerminalSettings extends StatefulWidget {
  const TerminalSettings({
    super.key,
    required this.remote,
    required this.runtime,
    required this.fontSize,
    required this.onFontSize,
    required this.canType,
    required this.model,
    required this.effort,
    required this.onModel,
    required this.onEffort,
  });

  final Remote remote;
  final String? runtime;
  final double fontSize;
  final ValueChanged<double> onFontSize;
  final bool canType;
  final String? model;
  final String? effort;
  final ValueChanged<String> onModel;
  final ValueChanged<String> onEffort;

  @override
  State<TerminalSettings> createState() => _TerminalSettingsState();
}

class _TerminalSettingsState extends State<TerminalSettings> {
  late double _fontSize = widget.fontSize;
  Map<String, dynamic>? _runtime;
  late String? _model = widget.model;
  late String? _effort = widget.effort;
  late String? _sentEffort = widget.effort;

  /// The slider's position while it is dragged.
  double? _dragging;
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
      setState(() {
        _runtime = runtimes
            .where((r) => r['name'] == widget.runtime)
            .firstOrNull;
        _model ??= _runtime?['defaultModel'] as String?;
        _effort ??= _runtime?['defaultEffort'] as String?;
      });
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

  List<Map<String, dynamic>> _options(Map<String, dynamic>? from, String key) =>
      ((from?[key] as List?) ?? const []).cast<Map<String, dynamic>>();

  String _label(Map<String, dynamic> option) =>
      option['label'] as String? ?? option['value'] as String;

  /// The runtime's efforts, narrowed to those the chosen model (or, before
  /// one is chosen, the default model) supports.
  List<Map<String, dynamic>> get _efforts {
    final all = _options(_runtime, 'efforts');
    final current = _model ?? _runtime?['defaultModel'] as String?;
    final model = _options(
      _runtime,
      'models',
    ).where((m) => m['value'] == current).firstOrNull;
    final supported = ((model?['supportedEfforts'] as List?) ?? const [])
        .cast<String>();
    if (supported.isEmpty) return all;
    return all.where((e) => supported.contains(e['value'])).toList();
  }

  void _chooseModel(String? model) {
    if (model == null || model == _model) return;
    setState(() => _model = model);
    widget.onModel(model);
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _models() {
    final models = _options(_runtime, 'models');
    if (models.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('模型'),
        RadioGroup<String>(
          groupValue: _model,
          onChanged: widget.canType ? _chooseModel : (_) {},
          child: Column(
            children: [
              for (final model in models)
                RadioListTile<String>(
                  key: Key('model-${model['value']}'),
                  value: model['value'] as String,
                  enabled: widget.canType,
                  title: Text(_label(model)),
                  dense: true,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _effortSlider() {
    final efforts = _efforts;
    if (efforts.isEmpty) return const SizedBox.shrink();
    final values = [for (final e in efforts) e['value'] as String];
    final chosen = values.indexOf(_effort ?? '');
    final index = _dragging ?? (chosen < 0 ? 0 : chosen).toDouble();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Text('Effort', style: theme.textTheme.titleSmall),
              ),
              Text(
                chosen < 0 && _dragging == null
                    ? '未选择'
                    : _label(efforts[index.round()]),
                key: const Key('effortValue'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
        if (efforts.length > 1)
          Slider(
            key: const Key('effort'),
            padding: const EdgeInsets.symmetric(horizontal: _sliderInset),
            value: index,
            max: (efforts.length - 1).toDouble(),
            divisions: efforts.length - 1,
            onChanged: widget.canType
                ? (v) => setState(() => _dragging = v)
                : null,
            onChangeEnd: (v) => _chooseEffort(values[v.round()]),
          ),
        // Each stop's name and what it means, under the stop.
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final count = efforts.length;
            final step = count > 1
                ? (width - 2 * _sliderInset) / (count - 1)
                : 0.0;
            final labelWidth = count > 1 ? step.clamp(48.0, 120.0) : width;
            return SizedBox(
              height: 44,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (var i = 0; i < count; i++)
                    Positioned(
                      left: count > 1
                          ? (_sliderInset + i * step - labelWidth / 2).clamp(
                              0.0,
                              width - labelWidth,
                            )
                          : 0,
                      width: labelWidth,
                      child: _effortLabel(
                        efforts[i],
                        selected:
                            i == index.round() &&
                            (chosen >= 0 || _dragging != null),
                        onTap: widget.canType
                            ? () => _chooseEffort(values[i])
                            : null,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  void _chooseEffort(String effort) {
    setState(() {
      _dragging = null;
      _effort = effort;
    });
    // Typed only when it differs from what was last sent from here.
    if (effort != _sentEffort) {
      _sentEffort = effort;
      widget.onEffort(effort);
    }
  }

  Widget _effortLabel(
    Map<String, dynamic> effort, {
    required bool selected,
    required VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final color = selected ? theme.colorScheme.primary : null;
    final value = effort['value'] as String;
    return InkWell(
      key: Key('effort-$value'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _label(effort),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: selected ? FontWeight.w600 : null,
            ),
          ),
          Text(
            effortHint(value),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color ?? theme.colorScheme.onSurfaceVariant,
            ),
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
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TextButton(
                  key: const Key('fontReset'),
                  onPressed: _fontSize == defaultFontSize
                      ? null
                      : () => _font(defaultFontSize),
                  child: const Text('恢复默认'),
                ),
              ),
            ),
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
            if (widget.runtime != null) const Divider(),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            _models(),
            _effortSlider(),
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
