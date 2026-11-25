/// Decides which terminal size the phone asks the host PTY for.
///
/// The phone always asks for the rows it has with the on-screen keyboard
/// closed, worked out ahead of time, so opening or closing the keyboard never
/// resizes the PTY: with the keyboard up the terminal keeps its rows and
/// scrolls. When the server's `rows` (from `snapshot` or `resized`) is larger
/// than that, the phone keeps the server's rows and reports only column
/// changes (font size, rotation), alongside the server's rows.
class TerminalSizePolicy {
  int? _cols;
  int? _rows;
  int? _closedRows;
  int? _serverRows;
  int? _reportedCols;
  int? _reportedRows;

  /// The phone terminal viewport's current `(cols, rows)`, or null before layout.
  (int, int)? get localSize =>
      _cols != null && _rows != null ? (_cols!, _rows!) : null;

  /// The phone's rows with the on-screen keyboard closed.
  int? get keyboardClosedRows => _closedRows;

  /// The latest row count reported by the server in `snapshot` or `resized`.
  int? get serverRows => _serverRows;

  /// Whether the server has more rows than the phone, so its rows are kept.
  bool get keepServerRows {
    final server = _serverRows;
    final closed = _closedRows;
    return server != null && closed != null && server > closed;
  }

  /// The `(cols, rows)` the phone wants the PTY to have.
  (int, int)? get wantedSize {
    final cols = _cols;
    final closed = _closedRows;
    if (cols == null || closed == null) return null;
    return (cols, keepServerRows ? _serverRows! : closed);
  }

  /// The `(cols, rows)` the local terminal emulator should use: local width
  /// and the server's rows once known, so its output lands where it was meant.
  (int, int)? get terminalSize {
    final wanted = wantedSize;
    if (wanted == null) return null;
    return (wanted.$1, _serverRows ?? wanted.$2);
  }

  /// The `(cols, rows)` to send for the very first `attach`.
  (int, int)? get initialAttachSize => wantedSize;

  /// The `(cols, rows)` to send for `takeControl` or a reconnect `attach`.
  (int, int)? get controlSize => wantedSize;

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
    _closedRows = keyboardClosedRows;
    final wanted = wantedSize!;
    // The server already has its rows: only a new width is news.
    if (keepServerRows) return _reportedCols == cols ? null : wanted;
    if (_reportedCols == wanted.$1 && _reportedRows == wanted.$2) return null;
    return wanted;
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
