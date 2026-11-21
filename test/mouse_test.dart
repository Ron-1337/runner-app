import 'package:flutter_test/flutter_test.dart';
import 'package:runner_app/core/mouse.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('each mouse mode is tracked on its own, as the snapshot lists them', () {
    final modes = MouseModes();
    expect(modes.tracking, isFalse);
    modes.scan('\x1bc\x1b[?1000h\x1b[?1002h\x1b[?1003l\x1b[?1006h\x1b[?1005l');
    expect(modes.tracking, isTrue);
    expect(modes.encoding, MouseReportMode.sgr);
    modes.scan('\x1b[?1000l\x1b[?1002l');
    expect(modes.tracking, isFalse);
  });

  test('a sequence split across chunks still counts', () {
    final modes = MouseModes();
    modes.scan('text\x1b[?10');
    modes.scan('02;1006h more');
    expect(modes.tracking, isTrue);
    expect(modes.encoding, MouseReportMode.sgr);
    modes.scan('\x1b');
    modes.scan('c');
    expect(modes.tracking, isFalse, reason: 'a reset clears every mode');
  });

  TerminalMouseEvent event(TerminalMouseButton button, {bool up = false}) =>
      TerminalMouseEvent(
        button: button,
        buttonState: up
            ? TerminalMouseButtonState.up
            : TerminalMouseButtonState.down,
        position: const CellOffset(4, 9),
        state: Terminal(),
        platform: TerminalTargetPlatform.android,
      );

  test('the wheel is reported as buttons 64 and 65', () {
    final modes = MouseModes();
    final handler = TrackedMouseHandler(modes);
    expect(handler(event(TerminalMouseButton.wheelUp)), isNull);
    modes.scan('\x1b[?1002h\x1b[?1006h');
    expect(handler(event(TerminalMouseButton.wheelUp)), '\x1b[<64;5;10M');
    expect(handler(event(TerminalMouseButton.wheelDown)), '\x1b[<65;5;10M');
    expect(
      handler(event(TerminalMouseButton.wheelDown, up: true)),
      isNull,
      reason: 'a wheel has no release',
    );
    expect(handler(event(TerminalMouseButton.left, up: true)), '\x1b[<0;5;10m');
    modes.scan('\x1b[?1006l');
    expect(
      handler(event(TerminalMouseButton.wheelUp)),
      '\x1b[M${String.fromCharCodes([96, 37, 42])}',
    );
  });
}
