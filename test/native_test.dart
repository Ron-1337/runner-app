import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:runner_remote/core/core.dart';

/// Talks to the real Rust library through dart:ffi. Build it first with
/// `cargo build --manifest-path rust/Cargo.toml`; CI does.
void main() {
  final built = File('rust/target/debug/librunner_mobile_core.so').existsSync();

  test('replies and errors cross the FFI boundary', () async {
    final core = NativeCore.instance;
    await expectLater(
      core.call('listComputers', {
        'origin': 'ftp://example.com',
        'credential': 'x',
      }),
      throwsA(
        isA<CoreException>().having(
          (e) => e.message,
          'message',
          '只支持 HTTPS 或 HTTP 地址',
        ),
      ),
    );
    await expectLater(
      core.call('frobnicate', {}),
      throwsA(
        isA<CoreException>().having(
          (e) => e.message,
          'message',
          startsWith('invalid command'),
        ),
      ),
    );
    await expectLater(
      core.request(99, {'type': 'overview'}),
      throwsA(
        isA<CoreException>().having((e) => e.message, 'message', '连接已关闭'),
      ),
    );
    // Many replies in flight at once each reach their own caller.
    final replies = await Future.wait([
      for (var i = 0; i < 50; i++)
        core.call('close', {'route': i}).then((v) => v ?? i),
    ]);
    expect(replies, List.generate(50, (i) => i));
  }, skip: built ? false : 'build rust/ first');
}
