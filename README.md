# Runner Remote

Runner 远程控制的手机客户端（Android 和 iOS），通过 runner-server 中继连接自己账号下的电脑。

## 功能

- 以手机身份登录 runner-server（device flow，在浏览器中批准）；手机不会出现在电脑列表里
- 查看账号下的电脑和在线状态
- 用电脑的 6 位 PIN 配对（CPace + Noise `XXpsk3`），之后用保存的密钥直接连接（Noise `IK`）
- 按工作区查看电脑上的任务、标签页和会话及状态，和桌面侧边栏一致
- 远程新建：聊天（选角色，或选运行时和模型）、终端、任务（选团队、标题、目标），可指定工作区和电脑上的工作目录
- 远程启动：已停止的会话点开即可启动，任务可停止和恢复；会话可重启、停止、重命名、归档
- 工作区：用电脑上的文件夹新建，重命名，删除（有运行中会话时确认后强制删除）
- 打开终端：接管控制、查看输出、输入，附带 Esc/Tab/Ctrl+C/方向键按键栏
- 只显示这台电脑上的 Runner 支持的操作（按 `welcome` 中的 features）

## 结构

| 目录 | 内容 |
| --- | --- |
| `rust/` | 协议核心：runner-server 的 HTTP 接口、中继连接、配对与加密通道、companion 请求。复用 Runner 的 `runner-core` |
| `lib/core/` | 通过 `dart:ffi` 调用 Rust 核心（`rmc_start`/`rmc_send`/`rmc_free`，收发 JSON）；登录凭据和配对密钥存在系统安全存储（iOS Keychain、Android Keystore） |
| `lib/pages/` | 界面：登录、电脑列表、会话列表、终端（xterm） |

## 开发

需要 Flutter 3.50.1 和 Rust stable。

```sh
cargo test --manifest-path rust/Cargo.toml
cargo build --manifest-path rust/Cargo.toml   # test/native_test.dart 要用到
flutter analyze
flutter test
```

`rust/tests/requests.rs` 用 Runner 自己的解析器检查 App 发出的每种请求；`rust/tests/e2e.rs` 启动一个真实的 runner-server，用 `runner-core` 的 host 端扮演电脑，测试登录、配对、终端和重连的全过程。对已部署的服务器做 TLS 连通检查：

```sh
RUNNER_ORIGIN=https://runner.example.com cargo test --manifest-path rust/Cargo.toml -- --ignored
```

## 构建

GitHub Actions（`.github/workflows/build.yml`）在每次推送到 `main` 和每个 PR 时运行测试并打包，产物在该次运行的 Artifacts 中下载：

| 产物 | 说明 |
| --- | --- |
| `runner-app-arm64-v8a.apk` 等 | 按 CPU 架构拆分的 APK，暂用调试密钥签名，可直接安装测试；大多数手机用 `arm64-v8a` |
| `runner-app-unsigned.ipa` | 未签名，需要用 Sideloadly、AltStore 等重签名后安装 |

Android 的 Rust 库由 `cargo ndk` 编译到 `android/app/src/main/jniLibs/`；iOS 链接 `rust/target/aarch64-apple-ios/release/librunner_mobile_core.a`（模拟器用 `aarch64-apple-ios-sim`），本地构建前需要先编译对应目标。

推送 `v*` 标签会创建预发布 Release，附带上述文件和 `SHA256SUMS`。

App ID：Android `dev.runner.runner_app`，iOS `dev.runner.runnerApp`。
