import 'package:xterm/xterm.dart';

/// The mouse modes the program in the terminal asked for, read from its output.
///
/// xterm.dart keeps a single mouse mode, so any `CSI ? 100x l` turns reporting
/// off, and `CSI ? 1005 l` turns SGR encoding off. The host's snapshot lists
/// every mode with `h` or `l` (`?1000h ?1002h ?1003l … ?1006h ?1005l`), which
/// leaves xterm.dart with no mouse reporting after attaching to a full-screen
/// program such as Claude Code. Swipes then turn into arrow keys instead of
/// wheel events, and the transcript cannot be scrolled. This tracks each mode
/// on its own, as other terminals do.
class MouseModes {
  final _on = <int>{};
  String _tail = '';

  static const _tracking = {1000, 1002, 1003};
  static const _known = {..._tracking, 1005, 1006, 1015};
  static final _sequence = RegExp(r'\x1bc|\x1b\[\?([0-9;]*)([hl])');

  /// Whether the program wants mouse reports.
  bool get tracking => _on.any(_tracking.contains);

  MouseReportMode get encoding => _on.contains(1006)
      ? MouseReportMode.sgr
      : _on.contains(1015)
      ? MouseReportMode.urxvt
      : _on.contains(1005)
      ? MouseReportMode.utf
      : MouseReportMode.normal;

  /// Reads terminal output; a sequence may be split across calls.
  void scan(String text) {
    final data = _tail + text;
    for (final match in _sequence.allMatches(data)) {
      if (match[0] == '\x1bc') {
        _on.clear();
        continue;
      }
      final on = match[2] == 'h';
      for (final part in match[1]!.split(';')) {
        final mode = int.tryParse(part);
        if (mode == null || !_known.contains(mode)) continue;
        on ? _on.add(mode) : _on.remove(mode);
      }
    }
    // Keeps what may be the start of a sequence the next chunk finishes.
    final escape = data.lastIndexOf('\x1b');
    final rest = escape < 0 ? '' : data.substring(escape);
    _tail = rest.length < 24 && !_sequence.hasMatch(rest) && _partial(rest)
        ? rest
        : '';
  }

  static bool _partial(String rest) =>
      RegExp(r'^\x1b(\[(\?[0-9;]*)?)?$').hasMatch(rest);
}

/// Reports clicks and the wheel as [modes] asks for them.
class TrackedMouseHandler implements TerminalMouseHandler {
  TrackedMouseHandler(this.modes);

  final MouseModes modes;

  @override
  String? call(TerminalMouseEvent event) {
    if (!modes.tracking) return null;
    final up = event.buttonState == TerminalMouseButtonState.up;
    final int code;
    switch (event.button) {
      case TerminalMouseButton.left:
        code = 0;
      case TerminalMouseButton.middle:
        code = 1;
      case TerminalMouseButton.right:
        code = 2;
      case TerminalMouseButton.wheelUp:
        code = 64;
      case TerminalMouseButton.wheelDown:
        code = 65;
      default:
        return null;
    }
    // A wheel has no release.
    if (up && code >= 64) return null;
    return encodeMouse(code, up, event.position, modes.encoding);
  }
}

/// A mouse report for button [code] at [position] (0-based).
String? encodeMouse(
  int code,
  bool release,
  CellOffset position,
  MouseReportMode encoding,
) {
  final x = position.x + 1;
  final y = position.y + 1;
  switch (encoding) {
    case MouseReportMode.sgr:
      return '\x1b[<$code;$x;$y${release ? 'm' : 'M'}';
    case MouseReportMode.urxvt:
      return '\x1b[${32 + (release ? 3 : code)};$x;${y}M';
    case MouseReportMode.normal:
    case MouseReportMode.utf:
      final limit = encoding == MouseReportMode.normal ? 223 : 2015;
      if (x > limit || y > limit) return null;
      return '\x1b[M${String.fromCharCodes([32 + (release ? 3 : code), 32 + x, 32 + y])}';
  }
}
