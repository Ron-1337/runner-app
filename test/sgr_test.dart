import 'package:flutter_test/flutter_test.dart';
import 'package:runner_remote/core/sgr.dart';
import 'package:xterm/xterm.dart';

bool underlined(Terminal terminal, int x) =>
    terminal.buffer.lines[0].getAttributes(x) & CellFlags.underline != 0;

void main() {
  test("Claude Code's modifyOtherKeys does not underline the screen", () {
    final terminal = Terminal();
    terminal.write(SgrFilter().apply('\x1b[>4;2mabc'));
    expect(underlined(terminal, 0), isFalse);
    expect(terminal.buffer.lines[0].toString(), startsWith('abc'));
  });

  test('sub-parameters are spelled out with semicolons', () {
    final filter = SgrFilter();
    expect(filter.apply('\x1b[4:0m'), '\x1b[24m');
    expect(filter.apply('\x1b[4:3m'), '\x1b[4m');
    expect(filter.apply('\x1b[38:2::1:2:3m'), '\x1b[38;2;1;2;3m');
    expect(filter.apply('\x1b[48:5:200m'), '\x1b[48;5;200m');
    expect(filter.apply('\x1b[1;58:5:4m'), '\x1b[1m');
    expect(filter.apply('\x1b[0;58;5;4;31m'), '\x1b[0;31m');
    expect(filter.apply('\x1b[58;2;4;4;4m'), '');
    expect(filter.apply('\x1b[0;38;5;158m'), '\x1b[0;38;5;158m');
    expect(filter.apply('plain \x1b[1;31mtext'), 'plain \x1b[1;31mtext');
  });

  test('underline is switched off by the colon form', () {
    final terminal = Terminal();
    final filter = SgrFilter();
    terminal.write(filter.apply('\x1b[4ma\x1b[4:0mb'));
    expect(underlined(terminal, 0), isTrue);
    expect(underlined(terminal, 1), isFalse);
  });

  test('a sequence split across chunks is held until complete', () {
    final filter = SgrFilter();
    expect(filter.apply('ab\x1b[>4'), 'ab');
    expect(filter.apply(';2mc'), 'c');
    expect(filter.apply('d\x1b'), 'd');
    expect(filter.apply('[2Je'), '\x1b[2Je');
  });
}
