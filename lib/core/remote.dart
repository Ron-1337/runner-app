import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'core.dart';

enum RemoteState { connected, reconnecting, failed }

/// One connected computer: its current route, the requests its Runner serves,
/// and reconnecting when the route drops.
///
/// A dropped route is reopened every [retryDelay], up to [maxAttempts] times;
/// after that, or on an error retrying cannot fix, it waits for [retry].
class Remote extends ChangeNotifier {
  Remote({
    required this.core,
    required int route,
    required Map<String, dynamic> welcome,
    required this.open,
  }) : _route = route {
    _welcome(welcome);
    _events = core.routeEvents.listen(_onEvent);
  }

  static const maxAttempts = 3;
  static const retryDelay = Duration(seconds: 5);

  final Core core;

  /// Opens a new route to the computer, as the `connect` command does.
  final Future<Map<String, dynamic>> Function() open;

  int _route;
  int get route => _route;
  var features = <String>{};

  /// The host's OS, which decides its path separator.
  var platform = '';

  var state = RemoteState.connected;

  /// The reconnect attempt under way or next, from 1 to [maxAttempts].
  var attempt = 0;
  String? lastError;

  late final StreamSubscription<RouteEvent> _events;
  final _pushes = StreamController<RouteEvent>.broadcast();
  Timer? _timer;
  var _disposed = false;

  void _welcome(Map<String, dynamic> welcome) {
    features = {...?(welcome['features'] as List?)?.cast<String>()};
    platform = welcome['platform'] as String? ?? '';
  }

  /// Pushes on the current route; its closes are handled here.
  Stream<RouteEvent> get pushes => _pushes.stream;

  bool get connected => state == RemoteState.connected;

  bool has(String feature) => features.contains(feature);

  void _onEvent(RouteEvent event) {
    if (event.route != _route) return;
    if (!event.closed) {
      _pushes.add(event);
      return;
    }
    if (state != RemoteState.connected) return;
    lastError = event.error ?? '连接已关闭';
    attempt = 0;
    _schedule();
  }

  void _schedule() {
    if (_disposed) return;
    if (attempt >= maxAttempts) {
      state = RemoteState.failed;
      notifyListeners();
      return;
    }
    attempt++;
    state = RemoteState.reconnecting;
    notifyListeners();
    _timer?.cancel();
    _timer = Timer(retryDelay, _reconnect);
  }

  Future<void> _reconnect() async {
    try {
      final opened = await open();
      if (_disposed) {
        unawaited(core.call('close', {'route': opened['route']}));
        return;
      }
      _route = opened['route'] as int;
      _welcome(opened['welcome'] as Map<String, dynamic>);
      state = RemoteState.connected;
      attempt = 0;
      lastError = null;
      notifyListeners();
    } catch (e) {
      if (_disposed) return;
      lastError = e.toString();
      if (_hopeless(lastError!)) attempt = maxAttempts;
      _schedule();
    }
  }

  /// Errors another attempt cannot fix.
  static bool _hopeless(String error) =>
      const ['不认识本机', '已被移除', '登录已失效', '找不到这台电脑', '指纹'].any(error.contains);

  /// Starts reconnecting again, after [maxAttempts] failed.
  void retry() {
    if (state != RemoteState.failed) return;
    attempt = 0;
    _schedule();
  }

  Future<dynamic> request(
    String type, [
    Map<String, Object?> fields = const {},
  ]) {
    if (!connected) return Future.error(CoreException('连接已断开，正在重连'));
    return core.request(_route, {'type': type, ...fields});
  }

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

  /// What a page shows while the route is down, or null when connected.
  String? get problem => switch (state) {
    RemoteState.connected => null,
    RemoteState.reconnecting => '连接已断开，正在重连（第 $attempt/$maxAttempts 次）…',
    RemoteState.failed => '无法重新连接：${lastError ?? '连接已关闭'}',
  };

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _events.cancel();
    _pushes.close();
    if (connected) unawaited(core.call('close', {'route': _route}));
    super.dispose();
  }
}

/// The banner a page shows while its computer is reconnecting or failed to.
class ReconnectBanner extends StatelessWidget {
  const ReconnectBanner({super.key, required this.remote});

  final Remote remote;

  @override
  Widget build(BuildContext context) {
    final problem = remote.problem;
    if (problem == null) return const SizedBox.shrink();
    final failed = remote.state == RemoteState.failed;
    return MaterialBanner(
      leading: failed
          ? const Icon(Icons.cloud_off)
          : const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
      content: Text(problem),
      actions: [
        if (failed)
          TextButton(
            key: const Key('reconnect'),
            onPressed: remote.retry,
            child: const Text('重新连接'),
          )
        else
          const SizedBox.shrink(),
      ],
    );
  }
}

/// A terminal size for starting a session before its terminal is on screen;
/// opening the terminal takes control at the screen's real size.
const startCols = 80;
const startRows = 24;
