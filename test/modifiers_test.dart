import 'package:flutter_test/flutter_test.dart';
import 'package:runner_remote/core/modifiers.dart';

void main() {
  test('modifiers change a single key as a terminal keyboard would', () {
    expect(applyModifiers('c', ctrl: true), '\x03');
    expect(applyModifiers('C', ctrl: true), '\x03');
    expect(applyModifiers('[', ctrl: true), '\x1b');
    expect(applyModifiers(' ', ctrl: true), '\x00');
    expect(applyModifiers('a', shift: true), 'A');
    expect(applyModifiers('b', alt: true), '\x1bb');
    expect(applyModifiers('x', ctrl: true, alt: true), '\x1b\x18');
    expect(applyModifiers('\x7f', ctrl: true), '\x08');
    expect(applyModifiers('hello', ctrl: true), 'hello');
  });
}
