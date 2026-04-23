<p align="center">
  <img src="docs/assets/easyrun-logo.svg" alt="easyRun" width="520">
</p>

<p align="center">
  A tiny native macOS launcher for building and running iOS apps without opening Xcode.
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS-lightgrey">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5-orange">
  <img alt="Xcode" src="https://img.shields.io/badge/Xcode-required-blue">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-green">
</p>

## Why

easyRun is for developers who use AI coding tools, terminals, or lightweight editors for iOS work, but still need a quick way to build, install, launch, stop, and inspect logs for an Xcode project.

It is not an IDE and it does not try to replace Xcode. It is a small native macOS control surface for the parts you need all day: project, scheme, device, run, stop, logs.

## Features

- Add a folder and automatically discover `.xcodeproj` / `.xcworkspace` files.
- Skip dependency folders such as `Pods`, `Carthage`, `SourcePackages`, `DerivedData`, `.build`, and `node_modules`.
- Pick scheme, configuration, and target device from the main window.
- Run and stop apps on iOS simulators and connected physical devices.
- Menu bar controls for quick Run / Stop and target-device selection.
- Device groups for physical devices, iPhone, iPad, Apple TV, Apple Watch, Vision, and other destinations.
- Build log and runtime log panels with search, copy, clear, capped rendering, and auto-scroll.
- Runtime log capture through `simctl` / `devicectl` console output where available.
- Project order can be changed by dragging rows in the sidebar.
- English and Simplified Chinese localization.

## Requirements

- macOS 13 Ventura or later.
- Xcode installed and selected with `xcode-select`.
- iOS simulator runtimes or connected iOS devices, depending on your target.
- For physical-device console output, a recent Xcode with `devicectl` support is recommended.

## Build From Source

```bash
git clone https://github.com/jimmyrogue/EasyRun.git
cd EasyRun
xcodebuild -project easyRun.xcodeproj -scheme easyRun -configuration Debug build
```

To open the project in Xcode:

```bash
open easyRun.xcodeproj
```

## Package A Test Build

The repository includes a simple local packaging script for tester builds:

```bash
bash scripts/package-test.sh
```

The script builds the Release configuration, ad-hoc signs the app, verifies the signature, and writes:

```text
build/distribution/easyRun-test.zip
```

Because this is not Developer ID signed or notarized, Gatekeeper may reject the app on another Mac. Testers can Control-click the app and choose Open, or you can replace the signing flow with your own Developer ID certificate and notarization process.

## Usage

1. Launch easyRun.
2. Click Add or drag a folder into the window.
3. Let easyRun scan for Xcode projects or workspaces.
4. Select a project from the sidebar.
5. Choose a scheme and target device.
6. Press Run.
7. Expand Logs when you need build or runtime output.

The app keeps running in the menu bar after the main window is closed, so you can run or stop projects without reopening the full window.

## How It Works

easyRun is a native SwiftUI + AppKit macOS app. The UI is intentionally close to Xcode's project navigator and toolbar patterns, while the execution layer shells out to Apple's own developer tools:

- `xcodebuild` for build operations.
- `xcrun simctl` for simulator boot, install, launch, stop, and console output.
- `xcrun devicectl` for modern physical-device install, launch, and console output.
- `xcrun xctrace` as a compatibility source for device discovery where needed.

Project configuration is stored locally under:

```text
~/Library/Application Support/LaunchPadiOS/projects.json
```

No project data is sent to a server.

## Project Structure

```text
easyRun/
  BuildProductResolver.swift   # Finds built .app products and bundle metadata.
  DeviceScanner.swift          # Discovers simulators and physical devices.
  LaunchPadStore.swift         # Main state and run/stop/clean orchestration.
  ProjectInspector.swift       # Reads schemes and project metadata.
  RuntimeLogController.swift   # Streams simulator/device runtime logs.
  ShellCommand.swift           # Async and streaming process helpers.
  StatusBarController.swift    # Menu bar integration.
  Project*View.swift           # SwiftUI window UI.
scripts/
  package-test.sh              # Local tester packaging script.
docs/assets/
  easyrun-logo.svg             # Project logo.
  easyrun-mark.svg             # App icon source mark.
```

## Roadmap

- Signed and notarized distribution workflow.
- Optional `.dmg` packaging.
- More robust physical-device diagnostics.
- Launch arguments and environment variable presets.
- Keyboard shortcuts for favorite projects.

## Contributing

Issues and pull requests are welcome. For UI changes, please keep the app native, compact, and developer-tool-like. For runtime changes, prefer Apple's built-in command-line tools before adding new dependencies.

Useful checks before opening a pull request:

```bash
xcodebuild -project easyRun.xcodeproj -scheme easyRun -configuration Debug build
git diff --check
```

## License

MIT. See [LICENSE](LICENSE).
