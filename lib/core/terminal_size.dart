/// Tracks the phone viewport's size against the host PTY's returned row count.
///
/// The first `attach` always reports the phone's own size. Afterwards, while
/// the server's `rows` (from `snapshot` or `resized`) is larger than the
/// phone's current rows — e.g. once the on-screen keyboard opens, the font
/// grows, or a taller desktop PTY took over — row changes are not reported:
/// the local terminal keeps the server's rows and scrolls instead. Column
/// changes (font size, rotation) are still sent, alongside the server's rows.
/// Rows are reported again only when the phone has at least as many rows as
/// the server.
class TerminalSizePolicy {
  int? _cols;
  int? _rows;
  int? _serverRows;
  int? _reportedCols;
  int? _reportedRows;

  /// The phone terminal viewport's current `(cols, rows)`, or null before layout.
  (int, int)? get localSize =>
      _cols != null && _rows != null ? (_cols!, _rows!) : null;

  /// The latest row count reported by the server in `snapshot` or `resized`.
  int? get serverRows => _serverRows;

  /// Whether row-count changes are currently suppressed in favor of [serverRows].
  bool get keepServerRows {
    final server = _serverRows;
    final rows = _rows;
    return server != null && rows != null && server > rows;
  }

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
  (int, int)? onViewport({required int cols, required int rows}) {
    _cols = cols;
    _rows = rows;
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
    if (rows > 0) _serverRows = rows;
  }

  /// Records a `(cols, rows)` pair sent in `attach`, `viewport` or `takeControl`.
  void recordReported(int cols, int rows) {
    _reportedCols = cols;
    _reportedRows = rows;
  }
}
