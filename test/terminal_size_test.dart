import 'package:flutter_test/flutter_test.dart';
import 'package:runner_remote/core/terminal_size.dart';

void main() {
  test('attaches with the keyboard-closed rows, even with the keyboard up', () {
    final policy = TerminalSizePolicy();
    expect(policy.onViewport(cols: 48, rows: 18, keyboardClosedRows: 35), (
      48,
      35,
    ));
    expect(policy.initialAttachSize, (48, 35));
    expect(policy.terminalSize, (48, 35));
  });

  test('the keyboard opening and closing never reports rows', () {
    final policy = TerminalSizePolicy();
    policy.onViewport(cols: 48, rows: 18, keyboardClosedRows: 35);
    policy.recordReported(48, 35);
    policy.onServerRows(35);

    expect(
      policy.onViewport(cols: 48, rows: 35, keyboardClosedRows: 35),
      isNull,
    );
    expect(
      policy.onViewport(cols: 48, rows: 18, keyboardClosedRows: 35),
      isNull,
    );
    expect(
      policy.onViewport(cols: 48, rows: 35, keyboardClosedRows: 35),
      isNull,
    );
    expect(policy.terminalSize, (48, 35));
  });

  test('keeps the server rows while they exceed the keyboard-closed rows', () {
    final policy = TerminalSizePolicy();
    policy.onViewport(cols: 48, rows: 35, keyboardClosedRows: 35);
    policy.recordReported(48, 35);
    policy.onServerRows(80);
    expect(policy.keepServerRows, isTrue);
    expect(policy.terminalSize, (48, 80));
    expect(
      policy.onViewport(cols: 48, rows: 35, keyboardClosedRows: 35),
      isNull,
      reason: 'the server already has its rows',
    );
    expect(policy.controlSize, (48, 80));

    // Font grows: fewer cols and rows; only cols change on the server.
    expect(policy.onViewport(cols: 39, rows: 28, keyboardClosedRows: 28), (
      39,
      80,
    ));
    policy.recordReported(39, 80);
    expect(
      policy.onViewport(cols: 39, rows: 14, keyboardClosedRows: 28),
      isNull,
    );
  });

  test('reports rows again once the phone has more than the server', () {
    final policy = TerminalSizePolicy();
    policy.onViewport(cols: 48, rows: 35, keyboardClosedRows: 35);
    policy.recordReported(48, 35);
    policy.onServerRows(35);

    // A larger font keeps the server's 35 rows.
    expect(policy.onViewport(cols: 39, rows: 28, keyboardClosedRows: 28), (
      39,
      35,
    ));
    policy.recordReported(39, 35);

    // A smaller font gives the phone more rows than the server: reported.
    expect(policy.onViewport(cols: 60, rows: 44, keyboardClosedRows: 44), (
      60,
      44,
    ));
  });
}
