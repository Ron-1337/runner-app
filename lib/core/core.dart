import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// An error the core reports, already worded for the person using the app.
class CoreException implements Exception {
  CoreException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A push from an open route, or its end (`message` is null, `error` says why).
class RouteEvent {
  RouteEvent(this.route, this.message, {this.closed = false, this.error});
  final int route;
  final Map<String, dynamic>? message;
  final bool closed;
  final String? error;

  String? get type => message?['type'] as String?;
}

/// The Rust core (`rust/`): runner-server's API and the encrypted channel.
abstract class Core {
  /// Runs one command; completes with its result or a [CoreException].
  Future<dynamic> call(String op, Map<String, Object?> args);

  Stream<RouteEvent> get routeEvents;

  /// Sends a companion request on an open route.
  Future<dynamic> request(int route, Map<String, Object?> message) =>
      call('request', {'route': route, 'message': message});

  /// Calls runner-server's NotifyService [method] (`GetSettings`,
  /// `SetSettings`, `Test`, `ListWatchers`, `PairWatcher`, `UnpairWatcher`,
  /// `ClaimSession`) as the account at [origin]; completes with its reply.
  Future<Map<String, dynamic>> notify(
    String origin,
    String credential,
    String method, [
    Map<String, Object?> body = const {},
  ]) async {
    final reply = await call('notify', {
      'origin': origin,
      'credential': credential,
      'method': method,
      'body': body,
    });
    return reply is Map<String, dynamic> ? reply : <String, dynamic>{};
  }
}

typedef _EventNative = Void Function(Pointer<Utf8>);
typedef _StartNative = Void Function(Pointer<NativeFunction<_EventNative>>);
typedef _StartDart = void Function(Pointer<NativeFunction<_EventNative>>);
typedef _SendNative = Int32 Function(Pointer<Utf8>);
typedef _SendDart = int Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

/// The core loaded from `librunner_mobile_core`, talking JSON over `dart:ffi`.
class NativeCore extends Core {
  NativeCore._(DynamicLibrary library)
    : _send = library.lookupFunction<_SendNative, _SendDart>('rmc_send'),
      _free = library.lookupFunction<_FreeNative, _FreeDart>('rmc_free') {
    _events = NativeCallable<_EventNative>.listener(_onEvent);
    library.lookupFunction<_StartNative, _StartDart>('rmc_start')(
      _events.nativeFunction,
    );
  }

  static NativeCore? _instance;

  static NativeCore get instance => _instance ??= NativeCore._(_open());

  static DynamicLibrary _open() {
    final path = Platform.environment['RMC_LIB'];
    if (path != null && path.isNotEmpty) return DynamicLibrary.open(path);
    // iOS links the static library into the app itself.
    if (Platform.isIOS) return DynamicLibrary.process();
    if (Platform.isAndroid) {
      return DynamicLibrary.open('librunner_mobile_core.so');
    }
    if (Platform.isMacOS) {
      return DynamicLibrary.open(
        'rust/target/debug/librunner_mobile_core.dylib',
      );
    }
    return DynamicLibrary.open('rust/target/debug/librunner_mobile_core.so');
  }

  final _SendDart _send;
  final _FreeDart _free;
  late final NativeCallable<_EventNative> _events;
  final _replies = <int, Completer<dynamic>>{};
  final _routes = StreamController<RouteEvent>.broadcast();
  var _next = 1;

  @override
  Stream<RouteEvent> get routeEvents => _routes.stream;

  @override
  Future<dynamic> call(String op, Map<String, Object?> args) {
    final id = _next++;
    final completer = Completer<dynamic>();
    _replies[id] = completer;
    final text = jsonEncode({...args, 'op': op, 'id': id}).toNativeUtf8();
    try {
      if (_send(text) != 0) {
        _replies.remove(id);
        completer.completeError(CoreException('内部错误：命令无效'));
      }
    } finally {
      malloc.free(text);
    }
    return completer.future;
  }

  void _onEvent(Pointer<Utf8> pointer) {
    final String text;
    try {
      text = pointer.toDartString();
    } finally {
      _free(pointer);
    }
    final event = jsonDecode(text) as Map<String, dynamic>;
    switch (event['type']) {
      case 'reply':
        final completer = _replies.remove(event['id']);
        if (completer == null) return;
        if (event['ok'] == true) {
          completer.complete(event['value']);
        } else {
          completer.completeError(CoreException(event['error'] as String));
        }
      case 'route':
        _routes.add(
          RouteEvent(
            event['route'] as int,
            event['message'] as Map<String, dynamic>,
          ),
        );
      case 'routeClosed':
        _routes.add(
          RouteEvent(
            event['route'] as int,
            null,
            closed: true,
            error: event['error'] as String?,
          ),
        );
    }
  }
}
