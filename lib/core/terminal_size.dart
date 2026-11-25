/// Tracks the phone viewport's size against the host PTY's returned row count.
///
/// The first `attach` always reports the phone's own size. Afterwards, if the
/// server returns a `rows` count larger than the terminal's height when the
/// on-screen keyboard is closed (e.g. a taller desktop PTY or server override),
/// row-only changes on the phone are no longer reported to the server while
/// column changes (such as font size or rotation) are still sent alongside the
/// server's row count.
class TerminalSizePolicy {
  int? _cols;
  int? _rows;
  int? _keyboardClosedRows;
  int? _serverRows;
  int? _reportedCols;
  int? _reportedRows;
  var _keepServerRows = false;

  /// The phone terminal viewport's current `(cols, rows)`, or null before layout.
  (int, int)? get localSize =>
      _cols != null && _rows != null ? (_cols!, _rows!) : null;

  /// The phone terminal's row count with the on-screen keyboard collapsed.
  int? get keyboardClosedRows => _keyboardClosedRows;

  /// The latest row count reported by the server in `snapshot` or `resized`.
  int? get serverRows => _serverRows;

  /// Whether row-count changes are currently suppressed in favor of [serverRows].
  bool get keepServerRows => _keepServerRows && _serverRows != null;

  /// The `(cols, rows)` the local terminal emulator should use: local width,
  /// and [serverRows] when row reporting is suppressed so tall server output
  /// renders without clipping.
  (int, int)? get terminalSize {
    final cols = _cols;
    final rows = _rows;
    if (cols == null || rows == null) return null;
    return (cols, keepServerRows ? _serverRows! : rows);
  }

  /// The `(cols, rows)` to send for the very first `attach`.
  (int, int)? get initialAttachSize => localSize;

  /// The `(cols, rows)` to send for `takeControl` or a reconnect `attach`.
  (int, int)? get controlSize => terminalSize;

  /// Updates the local viewport measurements and returns the `(cols, rows)`
  /// that should be sent in a `viewport` request, or null when nothing needs
  /// to be reported.
  (int, int)? onViewport({
    required int cols,
    required int rows,
    required int keyboardClosedRows,
  }) {
    _cols = cols;
    _rows = rows;
    _keyboardClosedRows = keyboardClosedRows;
    if (_keepServerRows &&
        _serverRows != null &&
        _serverRows! <= keyboardClosedRows) {
      _keepServerRows = false;
    }
    if (keepServerRows) {
      if (_reportedCols == cols) return null;
      return (cols, _serverRows!);
    }
    if (_reportedCols == cols && _reportedRows == rows) return null;
    return (cols, rows);
  }

  /// Updates the policy with the terminal `rows` returned by the server in a
  /// `snapshot` or `resized` message.
  void onServerRows(int rows) {
    if (rows <= 0) return;
    _serverRows = rows;
    final maxRows = _keyboardClosedRows;
    if (maxRows == null) return;
    if (rows <= maxRows) {
      _keepServerRows = false;
    } else if (_keepServerRows || rows != _reportedRows) {
      _keepServerRows = true;
    }
  }

  /// Records a `(cols, rows)` pair sent in `attach`, `viewport` or `takeControl`.
  void recordReported(int cols, int rows) {
    _reportedCols = cols;
    _reportedRows = rows;
  }
}
