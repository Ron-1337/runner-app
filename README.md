# Runner Remote

Runner 远程控制的手机客户端（Android 和 iOS），通过 runner-server 中继连接自己账号下的电脑。

- 界面：Flutter（`lib/`）
- 协议核心：Rust（`rust/`），复用 Runner 的 `runner-core`（Noise/CPace 通道和 companion 消息），之后通过 flutter_rust_bridge 接入界面

## 开发

需要 Flutter 3.50.1 和 Rust stable。

```sh
flutter pub get
flutter analyze
flutter test
cargo test --manifest-path rust/Cargo.toml
```

## 构建

GitHub Actions（`.github/workflows/build.yml`）在每次推送到 `main` 和每个 PR 时运行测试并打包，产物在该次运行的 Artifacts 中下载：

| 产物 | 说明 |
| --- | --- |
| `runner-app-arm64-v8a.apk` 等 | 按 CPU 架构拆分的 APK，暂用调试密钥签名，可直接安装测试 |
| `runner-app-unsigned.ipa` | 未签名，需要用 Sideloadly、AltStore 等重签名后安装 |

推送 `v*` 标签会创建预发布 Release，附带上述文件和 `SHA256SUMS`。

App ID：Android `dev.runner.runner_app`，iOS `dev.runner.runnerApp`。
