import 'package:flutter_test/flutter_test.dart';
import 'package:runner_remote/core/terminal_size.dart';

void main() {
  test(
    'reports both cols and rows normally when server rows fit the screen',
    () {
      final policy = TerminalSizePolicy();
      expect(policy.onViewport(cols: 48, rows: 35, keyboardClosedRows: 35), (
        48,
        35,
      ));
      expect(policy.initialAttachSize, (48, 35));
      policy.recordReported(48, 35);

      policy.onServerRows(35);
      expect(policy.keepServerRows, isFalse);

      // Keyboard opens: rows shrink, still reported normally.
      expect(policy.onViewport(cols: 48, rows: 18, keyboardClosedRows: 35), (
        48,
        18,
      ));
      policy.recordReported(48, 18);
      policy.onServerRows(18);
      expect(policy.keepServerRows, isFalse);

      // Keyboard closes: rows grow back, reported normally.
      expect(policy.onViewport(cols: 48, rows: 35, keyboardClosedRows: 35), (
        48,
        35,
      ));
      policy.recordReported(48, 35);
      policy.onServerRows(35);

      // Font gets larger: keyboard-closed rows shrink, but server did not return
      // oversized rows, so both cols and rows are reported normally.
      expect(policy.onViewport(cols: 39, rows: 28, keyboardClosedRows: 28), (
        39,
        28,
      ));
      expect(policy.keepServerRows, isFalse);
    },
  );

  test(
    'stops reporting row changes when server rows exceed keyboard-closed rows, '
    'while still reporting column changes',
    () {
      final policy = TerminalSizePolicy();
      policy.onViewport(cols: 48, rows: 35, keyboardClosedRows: 35);
      policy.recordReported(48, 35);

      // Server returns more rows than fit even with the keyboard closed.
      policy.onServerRows(80);
      expect(policy.keepServerRows, isTrue);
      expect(policy.terminalSize, (48, 80));
      expect(policy.controlSize, (48, 80));

      // Opening or closing the keyboard changes only rows: nothing reported.
      expect(
        policy.onViewport(cols: 48, rows: 18, keyboardClosedRows: 35),
        isNull,
      );
      expect(
        policy.onViewport(cols: 48, rows: 35, keyboardClosedRows: 35),
        isNull,
      );

      // Changing font size changes cols: reported with the server's rows.
      expect(policy.onViewport(cols: 39, rows: 28, keyboardClosedRows: 28), (
        39,
        80,
      ));
      policy.recordReported(39, 80);
      policy.onServerRows(80);
      expect(policy.keepServerRows, isTrue);

      // Keyboard toggle at the new font size still sends nothing.
      expect(
        policy.onViewport(cols: 39, rows: 14, keyboardClosedRows: 28),
        isNull,
      );
    },
  );

  test(
    'compares server rows against keyboard-closed rows even when opened with '
    'the keyboard up',
    () {
      final policy = TerminalSizePolicy();
      policy.onViewport(cols: 48, rows: 18, keyboardClosedRows: 35);
      policy.recordReported(48, 18);

      // Equal to keyboard-closed rows: does NOT suppress row reporting.
      policy.onServerRows(35);
      expect(policy.keepServerRows, isFalse);
      expect(policy.onViewport(cols: 48, rows: 35, keyboardClosedRows: 35), (
        48,
        35,
      ));

      // Strictly greater than keyboard-closed rows: suppresses row reporting.
      policy.onServerRows(36);
      expect(policy.keepServerRows, isTrue);
      expect(
        policy.onViewport(cols: 48, rows: 18, keyboardClosedRows: 35),
        isNull,
      );
    },
  );

  test(
    'resumes normal row reporting once server rows fit the screen again',
    () {
      final policy = TerminalSizePolicy();
      policy.onViewport(cols: 48, rows: 35, keyboardClosedRows: 35);
      policy.recordReported(48, 35);
      policy.onServerRows(80);
      expect(policy.keepServerRows, isTrue);

      // Server itself shrinks to fit.
      policy.onServerRows(30);
      expect(policy.keepServerRows, isFalse);
      expect(policy.terminalSize, (48, 35));
      expect(policy.onViewport(cols: 48, rows: 20, keyboardClosedRows: 35), (
        48,
        20,
      ));
    },
  );
}
