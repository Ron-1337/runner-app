import 'package:flutter_test/flutter_test.dart';
import 'package:runner_remote/core/terminal_size.dart';

void main() {
  test('attaches with the phone size and reports growth normally', () {
    final policy = TerminalSizePolicy();
    expect(policy.onViewport(cols: 48, rows: 35), (48, 35));
    expect(policy.initialAttachSize, (48, 35));
    policy.recordReported(48, 35);
    policy.onServerRows(35);
    expect(policy.keepServerRows, isFalse);

    // The phone gets taller than the server: rows are reported.
    expect(policy.onViewport(cols: 48, rows: 40), (48, 40));
    policy.recordReported(48, 40);
    policy.onServerRows(40);
    expect(policy.keepServerRows, isFalse);
    expect(policy.onViewport(cols: 48, rows: 40), isNull);
  });

  test('stops reporting rows once the server has more rows than the phone', () {
    final policy = TerminalSizePolicy();
    policy.onViewport(cols: 48, rows: 35);
    policy.recordReported(48, 35);
    policy.onServerRows(35);

    // Keyboard opens: the phone has fewer rows than the server, nothing sent,
    // and the local terminal keeps the server's rows.
    expect(policy.onViewport(cols: 48, rows: 18), isNull);
    expect(policy.keepServerRows, isTrue);
    expect(policy.terminalSize, (48, 35));
    expect(policy.controlSize, (48, 35));

    // Keyboard closes: back to the same rows, still nothing to send.
    expect(policy.onViewport(cols: 48, rows: 35), isNull);
    expect(policy.keepServerRows, isFalse);
  });

  test('still reports column changes with the server rows', () {
    final policy = TerminalSizePolicy();
    policy.onViewport(cols: 48, rows: 35);
    policy.recordReported(48, 35);
    policy.onServerRows(80);
    expect(policy.keepServerRows, isTrue);
    expect(policy.terminalSize, (48, 80));

    // Font grows: fewer cols and rows; only cols change on the server.
    expect(policy.onViewport(cols: 39, rows: 28), (39, 80));
    policy.recordReported(39, 80);
    policy.onServerRows(80);

    // Keyboard toggle at the new font size sends nothing.
    expect(policy.onViewport(cols: 39, rows: 14), isNull);
    expect(policy.onViewport(cols: 39, rows: 28), isNull);
  });

  test(
    'resumes reporting rows once the phone has at least the server rows',
    () {
      final policy = TerminalSizePolicy();
      policy.onViewport(cols: 48, rows: 18);
      policy.recordReported(48, 18);
      policy.onServerRows(30);
      expect(policy.keepServerRows, isTrue);
      expect(policy.onViewport(cols: 48, rows: 25), isNull);

      // Equal to the server's rows: nothing is suppressed any more.
      expect(policy.onViewport(cols: 48, rows: 30), (48, 30));
      policy.recordReported(48, 30);

      // The server itself shrinks below the phone: rows follow the phone.
      policy.onServerRows(20);
      expect(policy.keepServerRows, isFalse);
      expect(policy.terminalSize, (48, 30));
    },
  );
}
