import 'core.dart';

/// One connected computer: its route and the requests its Runner serves.
class Remote {
  Remote({
    required this.core,
    required this.route,
    required Map<String, dynamic> welcome,
  }) : features = {...?(welcome['features'] as List?)?.cast<String>()},
       platform = welcome['platform'] as String? ?? '';

  final Core core;
  final int route;
  final Set<String> features;

  /// The host's OS, which decides its path separator.
  final String platform;

  bool has(String feature) => features.contains(feature);

  Future<dynamic> request(
    String type, [
    Map<String, Object?> fields = const {},
  ]) => core.request(route, {'type': type, ...fields});

  /// Roles, runtimes, crews, workspaces and recent folders for starting things.
  Future<Map<String, dynamic>> catalog() async =>
      await request('catalog') as Map<String, dynamic>;

  /// Subfolders of [path] on the computer (its home folder when null).
  Future<Map<String, dynamic>> folders(String? path) async =>
      await request('folders', {'path': path}) as Map<String, dynamic>;

  String join(String folder, String name) {
    final separator = platform == 'windows' || folder.contains(r'\')
        ? r'\'
        : '/';
    return folder.endsWith(separator)
        ? '$folder$name'
        : '$folder$separator$name';
  }
}

/// A terminal size for starting a session before its terminal is on screen;
/// opening the terminal takes control at the screen's real size.
const startCols = 80;
const startRows = 24;
