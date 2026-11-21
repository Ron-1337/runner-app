import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

/// The phone keyboard's connection to the terminal.
///
/// xterm.dart's own text input asks for no suggestions, which Flutter turns
/// into a visible-password field on Android; Chinese and other composing
/// keyboards then offer only Latin letters. This connection allows them, and
/// sends a word to the terminal once the keyboard commits it.
///
/// The field always holds two spaces with the caret at the end, so a
/// backspace has something to delete and is noticed.
class TerminalKeyboard extends StatefulWidget {
  const TerminalKeyboard({
    super.key,
    required this.focusNode,
    required this.readOnly,
    required this.onText,
    required this.onBackspace,
    required this.onEnter,
    required this.onComposing,
    required this.child,
  });

  final FocusNode focusNode;
  final bool readOnly;

  /// Committed text, without newlines.
  final ValueChanged<String> onText;
  final VoidCallback onBackspace;
  final VoidCallback onEnter;

  /// What the keyboard is composing, such as pinyin; null once committed.
  final ValueChanged<String?> onComposing;
  final Widget child;

  @override
  State<TerminalKeyboard> createState() => TerminalKeyboardState();
}

class TerminalKeyboardState extends State<TerminalKeyboard>
    with TextInputClient {
  static const _base = TextEditingValue(
    text: '  ',
    selection: TextSelection.collapsed(offset: 2),
  );

  TextInputConnection? _connection;
  TextEditingValue _value = _base;

  bool get _attached => _connection?.attached ?? false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onFocus());
  }

  @override
  void didUpdateWidget(TerminalKeyboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_onFocus);
      widget.focusNode.addListener(_onFocus);
    }
    if (old.readOnly != widget.readOnly) _onFocus();
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    _close();
    super.dispose();
  }

  void _onFocus() {
    if (!mounted) return;
    if (widget.focusNode.hasFocus && !widget.readOnly) {
      _open();
    } else {
      _close();
    }
  }

  /// Brings the keyboard up, also when it was dismissed with focus kept.
  void show() {
    if (widget.focusNode.hasFocus) {
      _open();
    } else {
      widget.focusNode.requestFocus();
    }
  }

  void _open() {
    if (widget.readOnly) return;
    if (!_attached) {
      _connection = TextInput.attach(
        this,
        const TextInputConfiguration(
          inputType: TextInputType.multiline,
          inputAction: TextInputAction.newline,
          autocorrect: false,
          // False would make Android's keyboard a password field.
          enableSuggestions: true,
          enableIMEPersonalizedLearning: false,
        ),
      );
      _value = _base;
      _connection!.setEditingState(_value);
    }
    _connection!.show();
  }

  void _close() {
    if (_attached) _connection!.close();
    _connection = null;
    widget.onComposing(null);
  }

  void _reset() {
    _value = _base;
    if (_attached) _connection!.setEditingState(_base);
  }

  @override
  TextEditingValue? get currentTextEditingValue => _value;

  @override
  void updateEditingValue(TextEditingValue value) {
    _value = value;
    if (!value.composing.isCollapsed && value.composing.isValid) {
      widget.onComposing(value.composing.textInside(value.text));
      return;
    }
    widget.onComposing(null);
    final text = value.text;
    if (text == _base.text) return;
    if (text.length < _base.text.length && _base.text.startsWith(text)) {
      for (var i = text.length; i < _base.text.length; i++) {
        widget.onBackspace();
      }
    } else {
      // What follows the two spaces; a keyboard that replaced them sends all.
      final inserted = text.startsWith(_base.text)
          ? text.substring(_base.text.length)
          : text.trimLeft();
      final lines = inserted.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (i > 0) widget.onEnter();
        if (lines[i].isNotEmpty) widget.onText(lines[i]);
      }
    }
    _reset();
  }

  @override
  void performAction(TextInputAction action) {
    // A newline arrives as text; only a keyboard with a return action key
    // sends it as an action.
    if (action == TextInputAction.done ||
        action == TextInputAction.send ||
        action == TextInputAction.go) {
      widget.onEnter();
    }
  }

  @override
  void connectionClosed() {
    _connection = null;
    widget.onComposing(null);
  }

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  Widget build(BuildContext context) => widget.child;
}
