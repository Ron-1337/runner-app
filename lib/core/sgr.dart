/// Rewrites terminal output that xterm.dart misreads as text styles.
///
/// xterm.dart handles every `CSI … m` as SGR, whatever its prefix, and drops
/// the `:` of sub-parameters. So Claude Code's `CSI > 4 ; 2 m` (turning on
/// modifyOtherKeys) underlines and dims everything after it, `CSI 4 : 0 m`
/// (underline off) becomes 40 (black background), and the underline colour
/// `58 ; 5 ; n` sets blink and whatever SGR `n` is. This drops prefixed
/// sequences and the underline colour, and spells sub-parameters out with
/// semicolons. A sequence split across chunks is held until it is complete.
class SgrFilter {
  String _pending = '';

  static final _sequence = RegExp(r'\x1b\[([<=>?]?)([0-9:;]*)m');
  static final _underlineColour = RegExp(r'(^|;)5[89](;|$)');
  static final _unfinished = RegExp(r'^\x1b(\[[<=>?]?[0-9:;]*)?$');

  String apply(String text) {
    var data = _pending + text;
    _pending = '';
    final escape = data.lastIndexOf('\x1b');
    if (escape >= 0 &&
        data.length - escape < 64 &&
        _unfinished.hasMatch(data.substring(escape))) {
      _pending = data.substring(escape);
      data = data.substring(0, escape);
    }
    if (!data.contains('\x1b[')) return data;
    return data.replaceAllMapped(_sequence, (match) {
      if (match[1]!.isNotEmpty) return '';
      final params = match[2]!;
      // The common case needs no rewriting.
      if (!params.contains(':') && !_underlineColour.hasMatch(params)) {
        return match[0]!;
      }
      final clean = normalizeSgr(params);
      return clean == null ? '' : '\x1b[${clean}m';
    });
  }
}

/// [params] of an SGR as xterm.dart understands them; null when nothing is left.
String? normalizeSgr(String params) {
  if (params.isEmpty) return '';
  final out = <String>[];
  final fields = params.split(';');
  for (var i = 0; i < fields.length; i++) {
    final parts = fields[i].split(':');
    final code = int.tryParse(parts[0]) ?? 0;
    if (parts.length > 1) {
      // Sub-parameters: `4:n`, `38:2:[cs]:r:g:b`, `38:5:n`, `58:…`.
      final sub = [for (final p in parts.skip(1)) int.tryParse(p) ?? 0];
      switch (code) {
        case 4:
          out.add(sub.first == 0 ? '24' : '4');
        case 38 || 48:
          if (sub.first == 5 && sub.length >= 2) {
            out.add('$code;5;${sub[1]}');
          } else if (sub.first == 2 && sub.length >= 4) {
            final rgb = sub.sublist(sub.length - 3);
            out.add('$code;2;${rgb.join(';')}');
          }
        case 58:
          break;
        default:
          out.add('$code');
      }
      continue;
    }
    switch (code) {
      case 38 || 48 || 58:
        final mode = i + 1 < fields.length ? int.tryParse(fields[i + 1]) : null;
        final take = mode == 5
            ? 2
            : mode == 2
            ? 4
            : 0;
        if (take == 0 || i + take >= fields.length) {
          // Incomplete: drop the rest rather than read colours as styles.
          i = fields.length;
          continue;
        }
        if (code != 58) out.add(fields.sublist(i, i + take + 1).join(';'));
        i += take;
      case 59:
        break;
      default:
        out.add(fields[i]);
    }
  }
  return out.isEmpty ? null : out.join(';');
}
