<p align="center">
  <img src="docs/assets/easyrun-logo.svg" alt="easyRun" width="520">
</p>

<p align="center">
  A tiny native macOS launcher for building and running iOS apps without opening Xcode.
</p>

<p align="center">
  一个轻量的原生 macOS 工具，用来快速构建、安装和启动 iOS 项目，不必打开 Xcode。
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS-lightgrey">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5-orange">
  <img alt="Xcode" src="https://img.shields.io/badge/Xcode-required-blue">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-green">
</p>

## What Is easyRun?

easyRun is a small menu bar app for iOS developers who spend most of their time in AI coding tools, terminals, or lightweight editors, but still need a quick way to run an Xcode project on a simulator or a real device.

easyRun 是一个常驻菜单栏的 macOS 小工具，适合用 AI 编程工具、终端或轻量编辑器开发 iOS 项目的人。它不替代 Xcode，只把日常最常用的运行流程做得更快。

## What Can It Do?

- Add an `.xcodeproj` or `.xcworkspace` and discover available schemes automatically.
- Choose a target scheme and a simulator or connected iOS device.
- Build, install, run, stop, and restart apps from the main window or menu bar.
- Keep running in the menu bar after the main window is closed.
- View build logs and runtime logs when something fails.
- Save project configuration locally on your Mac.

## 能做什么？

- 添加 `.xcodeproj` 或 `.xcworkspace`，自动识别可用 Scheme。
- 选择 Target 和目标设备，支持模拟器和已连接真机。
- 在主窗口或菜单栏里启动、停止、重启 App。
- 关闭主窗口后继续常驻菜单栏，随时可以快速操作。
- 查看构建日志和运行时日志，方便排查失败原因。
- 项目配置只保存在本机。

## Requirements / 环境要求

- macOS 13 Ventura or later.
- Xcode installed and selected with `xcode-select`.
- iOS simulator runtimes or connected iOS devices.
- A recent Xcode is recommended for physical-device console logs.

## Build / 本地构建

```bash
git clone https://github.com/jimmyrogue/EasyRun.git
cd EasyRun
xcodebuild -project easyRun.xcodeproj -scheme easyRun -configuration Debug build
```

To open the project in Xcode:

```bash
open easyRun.xcodeproj
```

## Package / 本地打包

```bash
bash scripts/package-test.sh
```

The script creates a local tester build at:

```text
build/distribution/easyRun-test.zip
```

This build is ad-hoc signed and not notarized, so macOS Gatekeeper may warn on another Mac.

## License / 许可证

MIT. See [LICENSE](LICENSE).
