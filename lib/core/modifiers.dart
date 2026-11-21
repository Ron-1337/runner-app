/// What the phone keyboard's next key [data] sends with Ctrl, Alt and Shift
/// held, as a terminal keyboard would send it.
///
/// Only a single character is changed; longer input (a paste, a word from the
/// keyboard's suggestions, a mouse report) passes unchanged.
String applyModifiers(
  String data, {
  bool ctrl = false,
  bool alt = false,
  bool shift = false,
}) {
  if (data.runes.length != 1) return data;
  var text = data;
  if (shift) text = text.toUpperCase();
  if (ctrl) text = _control(text);
  if (alt) text = '\x1b$text';
  return text;
}

String _control(String char) {
  final code = char.codeUnitAt(0);
  if ((code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a)) {
    return String.fromCharCode(code & 0x1f);
  }
  return switch (char) {
    ' ' || '@' || '2' => '\x00',
    '[' || '3' => '\x1b',
    '\\' || '4' => '\x1c',
    ']' || '5' => '\x1d',
    '^' || '6' => '\x1e',
    '_' || '-' || '7' => '\x1f',
    '?' || '8' => '\x7f',
    '\x7f' => '\x08',
    _ => char,
  };
}
