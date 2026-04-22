# LaunchPad for iOS — Spec

> 一个极简的 macOS 桌面小工具，用于一键把 iOS 项目跑到模拟器或真机上。
> 目标用户：使用 AI 编程（Claude Code、Codex 等）开发 iOS 项目，不想打开 Xcode / VS Code，只需要"运行"的人。

---

## 1. 设计原则

1. **专注一件事**：build + run 到模拟器或真机。不做编辑、不做调试器 UI、不做 Xcode 的替代品。
2. **零命令行**：全部操作在 GUI 里完成，用户不需要知道 `xcodebuild` / `xcrun simctl` 存在。
3. **零配置起步**：拖一个 `.xcodeproj` 进来就能跑。复杂配置是"可选"而不是"必填"。
4. **常驻后台**：菜单栏图标始终在，需要的时候点一下就跑。
5. **透明可见**：编译失败、模拟器未启动、真机未连接等情况，用清晰的文字说明给用户，不藏错。

---

## 2. 产品形态

**✅ 已确认：主窗口 App + 菜单栏图标（双形态）**

- **主窗口**：管理项目列表（增删改）、查看日志、配置项目参数、切换设备。
- **菜单栏图标**：常驻，点开是一个下拉菜单列出所有项目，点哪个跑哪个。这是高频入口。

启动行为：
- 双击 app 图标 → 显示主窗口
- 关闭主窗口 → app 继续在菜单栏运行（不退出）
- 菜单栏 → "Quit" 才彻底退出

---

## 3. 核心用户流程

### 3.1 添加项目

**✅ 已确认：拖拽 .xcodeproj/.xcworkspace 自动识别**

1. 用户打开主窗口 → 看到项目列表（空状态提示"拖拽 .xcodeproj 或 .xcworkspace 到这里"）
2. 拖一个项目文件进来 → app 自动调用 `xcodebuild -list` 读取 scheme 列表
3. 弹一个小表单，已预填好：
   - 项目名称（默认取文件夹名，可改）
   - Scheme（下拉选，默认选第一个）
   - 目标设备（下拉选已安装的模拟器 + 已连接真机，默认 iPhone 16 或最新 iPhone）
   - Bundle ID（自动从 Info.plist 或 project.pbxproj 读取，可改）
4. 用户点"保存"→ 项目加入列表

> **备选入口**：菜单栏 → "Add Project..." 也可以触发文件选择对话框。
> **批量添加**：支持一次拖多个项目进来。

### 3.2 运行项目（菜单栏，高频场景）

1. 用户点菜单栏图标 → 下拉菜单显示：
   ```
   ▶ Project A      ⌘1
   ▶ Project B      ⌘2
   ▶ Project C      ⌘3
   ─────────────
   Show Main Window
   Preferences...
   Quit
   ```
2. 点某个项目 → 图标开始转圈动画
3. 后台依次执行：
   - 启动模拟器（如果目标模拟器未 boot）
   - `xcodebuild build`（增量编译）
   - `simctl install` 安装 .app
   - `simctl launch` 启动 app
4. 成功 → 图标恢复，右上角弹 macOS 原生通知"Project A launched"
5. 失败 → 图标变红，通知"Build failed - Click for details"，点通知跳到主窗口的错误详情页

### 3.3 运行项目（主窗口）

主窗口每个项目卡片上有：
- **Run** 按钮（主按钮）
- **Stop** 按钮（运行中可用）
- **Clean** 按钮（清理 DerivedData）
- 状态指示灯：灰=空闲 / 黄=编译中 / 绿=运行中 / 红=失败
- 底部小字：上次运行时间、用时

### 3.4 查看日志

点项目卡片 → 展开下半部分的日志面板，显示：
- **Build Log**（xcodebuild 输出，失败时默认自动展开错误行）
- **Runtime Log**（`simctl spawn booted log stream` 过滤该 bundle ID 的输出）

日志可以搜索、复制、清空。

---

## 4. 主窗口 UI 草图

```
┌─────────────────────────────────────────────────────────────┐
│ LaunchPad for iOS                              [+ Add]  [⚙] │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ 🟢 Project A                                          │ │
│  │    iPhone 16 · Debug · Scheme: ProjectA               │ │
│  │    Last run: 2 min ago (8.3s)                         │ │
│  │                            [▶ Run] [■ Stop] [🧹 Clean]│ │
│  └───────────────────────────────────────────────────────┘ │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ ⚪ Project B                                          │ │
│  │    iPhone 16 Pro · Debug · Scheme: ProjectB           │ │
│  │    Never run                                          │ │
│  │                            [▶ Run] [■ Stop] [🧹 Clean]│ │
│  └───────────────────────────────────────────────────────┘ │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ 🔴 Project C                                          │ │
│  │    iPhone 16 · Debug · Build failed                   │ │
│  │    ▼ AppDelegate.swift:42: Cannot find 'foo' in scope │ │
│  │                            [▶ Run] [■ Stop] [🧹 Clean]│ │
│  └───────────────────────────────────────────────────────┘ │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

每个卡片点击可展开 → 显示日志面板和详细配置（scheme / 设备 / configuration）。

---

## 5. 技术方案

### 5.1 技术栈

- **语言**：Swift
- **UI 框架**：SwiftUI（主窗口）+ AppKit（菜单栏 `NSStatusItem`）
- **最低系统**：macOS 13 Ventura（SwiftUI 足够成熟）
- **分发**：先本地 Archive 出 .app；后续可考虑 Developer ID 签名后用 Sparkle 做自动更新，Mac App Store 不考虑（需要沙盒，调用 xcodebuild 会很麻烦）

> **为什么不用 Electron / Tauri**：这个工具会频繁执行 shell 命令、读文件系统、监听通知，原生 Swift 在 macOS 上开销最低、交付最干净，而且跟 Xcode 工具链天然亲和。

### 5.2 核心能力实现

所有"动作"本质都是 `Process` 调用命令行工具。下面这些是**内部实现**，用户永远看不到：

| 动作 | 底层命令 |
|------|---------|
| 列出项目的 scheme | `xcodebuild -list -project <path>` / `-workspace <path>` |
| 列出可用模拟器 | `xcrun simctl list devices available --json` |
| 列出真机 | `xcrun devicectl list devices` (iOS 17+) / `xcrun xctrace list devices` |
| 启动模拟器 | `xcrun simctl boot <udid>` + `open -a Simulator` |
| 编译 | `xcodebuild build -project/-workspace ... -scheme ... -destination ... -derivedDataPath ...` |
| 安装到模拟器 | `xcrun simctl install <udid> <app-path>` |
| 启动 app | `xcrun simctl launch <udid> <bundle-id>` |
| 停止 app | `xcrun simctl terminate <udid> <bundle-id>` |
| 运行时日志 | `xcrun simctl spawn <udid> log stream --predicate 'subsystem == "<bundle-id>"'` |
| 清理 | 删除 `derivedDataPath` 目录 |
| 真机安装（v2） | `xcrun devicectl device install app --device <udid> <app-path>` |

> 关键约束：**用户必须装了 Xcode**（或至少 Xcode Command Line Tools + iOS Simulator runtime）。App 启动时检测 `xcode-select -p`，没装则引导用户去下载。

### 5.3 编译产物定位

`xcodebuild` 的 `.app` 输出路径是：
```
<derivedDataPath>/Build/Products/Debug-iphonesimulator/<SchemeName>.app
```
为了稳妥，用 `xcodebuild -showBuildSettings` 读 `BUILT_PRODUCTS_DIR` 和 `FULL_PRODUCT_NAME`，而不是硬拼路径。

### 5.4 状态管理

每个项目有一个状态机：
```
idle → building → installing → running
  ↑                                ↓
  └──────── stopped ←──────────────┘
  ↑
  └──── failed (可从任一中间态转入)
```

用 Swift 的 `@Observable` / `Combine` 驱动 UI 更新。

### 5.5 数据持久化

项目配置存在 `~/Library/Application Support/LaunchPadiOS/projects.json`：

```json
{
  "projects": [
    {
      "id": "uuid",
      "name": "Project A",
      "path": "/Users/xx/code/ProjectA/ProjectA.xcodeproj",
      "type": "project",
      "scheme": "ProjectA",
      "configuration": "Debug",
      "simulatorUDID": "ABCD-1234",
      "bundleID": "com.xx.projecta",
      "derivedDataPath": "~/Library/Developer/Xcode/DerivedData/LaunchPad-ProjectA",
      "createdAt": "2026-04-22T10:00:00Z",
      "lastRunAt": "2026-04-22T11:30:00Z",
      "lastRunDuration": 8.3
    }
  ]
}
```

---

## 6. 功能范围

**✅ 已确认功能清单（全部进 V1）：Run / Stop / Clean / 实时日志 / 切换模拟器 / 真机部署**

### V1（MVP）

核心流程：
- [x] 菜单栏图标 + 下拉运行
- [x] 主窗口项目列表
- [x] 拖拽添加项目，自动识别 scheme
- [x] 配置持久化

项目操作：
- [x] **Run** — 编译 + 安装 + 启动
- [x] **Stop** — 终止运行中的 app
- [x] **Clean** — 清理 DerivedData
- [x] **切换设备** — 在项目卡片上直接下拉选模拟器或已连接的真机
- [x] **部署到真机** — 检测连接的设备、处理签名、安装、启动

日志与反馈:
- [x] Build Log（xcodebuild 输出）
- [x] Runtime Log（app 运行时的 console 输出，实时 stream）
- [x] 日志搜索、复制、清空
- [x] 项目状态指示灯（idle / building / running / failed）
- [x] 编译失败的错误行高亮 + 点击跳转源码位置（调用 `open -a Xcode file:line`？或用 VS Code URL scheme？待定）
- [x] 原生 macOS 通知（成功/失败）

### V2（之后迭代）

- [ ] 多 scheme / configuration 切换（每次 Run 前可切换）
- [ ] 环境变量 / 启动参数自定义
- [ ] 全局快捷键（⌘⇧1/2/3…）运行对应项目
- [ ] 增量编译加速（xcodemake 集成）
- [ ] 菜单栏运行时显示"当前运行中"的项目名
- [ ] 构建耗时统计图
- [ ] 失败时自动把错误复制到剪贴板（方便贴给 Claude Code）
- [ ] 无线真机部署（Wi-Fi 连接的设备）

### 明确不做

- ❌ 代码编辑
- ❌ Git 集成
- ❌ 断点调试 / LLDB UI
- ❌ UI 设计预览
- ❌ 架构/依赖分析

---

## 7. 真机部署专题（⚠️ 复杂度提示）

把真机放进 V1 是最重的一个决定，这里单独说明技术方案和已知坑。

### 7.1 设备发现

- iOS 17+：`xcrun devicectl list devices --json-output -` → 得到设备 UDID、名称、连接状态
- iOS 16 及以下：用 `xcrun xctrace list devices` 兼容
- 首次连接的 iPhone 需要在设备上"信任此电脑"——app 要检测并提示用户
- 设备锁屏时部分命令会失败——需要引导用户解锁

### 7.2 代码签名

真机部署必须有有效签名。策略如下：

**策略 A：依赖项目自身的签名配置（推荐，V1 用这个）**
- 用户必须已经在 Xcode 里配好了"Automatic signing"或"Manual signing"
- app 直接用项目现有配置编译
- 好处：零配置，坏处：项目没配过的话第一次还得打开 Xcode 配一下（不过是一次性的）

**策略 B：app 内部帮用户管理签名（V2 再考虑）**
- 读取用户的 Apple ID、证书、provisioning profiles
- 工程量和 Xcode 本身的"Signing & Capabilities"面板相当，不值当

### 7.3 命令

| 动作 | 命令 |
|------|------|
| 编译给真机 | `xcodebuild build -destination 'generic/platform=iOS' -configuration Debug CODE_SIGN_STYLE=Automatic` |
| 找到 .app 产物 | 从 `xcodebuild -showBuildSettings` 读 `BUILT_PRODUCTS_DIR` |
| 安装到设备 | `xcrun devicectl device install app --device <UDID> <app-path>` |
| 启动 app | `xcrun devicectl device process launch --device <UDID> <bundle-id>` |
| 查看运行时日志 | `idevicesyslog`（需 libimobiledevice）或 `devicectl` 的 log 功能 |

### 7.4 已知的坑

1. **developer mode**：iOS 16+ 用户必须在"设置 → 隐私与安全 → 开发者模式"里开启，app 要能检测并引导
2. **free provisioning 的 7 天限制**：非付费开发者账号签的 app 7 天后失效，需要提醒用户
3. **首次运行设备上的信任**：用户需在设备"设置 → 通用 → VPN 与设备管理"里信任证书，一次性操作
4. **多设备连接**：project 卡片的设备下拉要同时列出模拟器和真机，用小图标区分

### 7.5 降级策略

如果用户没装 Xcode 只装了 Command Line Tools，或者签名环境不完整，真机部署应该**优雅失败**：
- 禁用"Run on Device"按钮并用 tooltip 说明原因
- 不要让用户点了以后才报错

> 基于以上，真机部署的实现工作量约 **4–5 天**，算在下面的里程碑里。

---

## 8. 开发里程碑

| 阶段 | 内容 | 预估 |
|------|------|------|
| M1 | 脚手架：SwiftUI app + 菜单栏图标 + 持久化框架 | 1–2 天 |
| M2 | 项目添加流程（拖拽、`xcodebuild -list` 解析、表单） | 2–3 天 |
| M3 | 模拟器 Run 流程（boot sim → build → install → launch） | 3–4 天 |
| M4 | 日志管道（Build Log + Runtime Log 实时 stream） | 2–3 天 |
| M5 | Stop / Clean / 设备切换 / 错误解析 / 状态指示灯 | 2–3 天 |
| M6 | **真机部署**（devicectl 集成、签名错误处理、developer mode 检测） | 4–5 天 |
| M7 | 打磨：空状态、错误文案、图标设计、通知、菜单栏快捷键 | 2–3 天 |
| M8 | 打包、Developer ID 签名、公证（notarization）、DMG 制作 | 1–2 天 |
| **合计** |  | **约 17–25 天（全职）** |

业余时间（每天 2–3 小时）开发的话大约 **6–9 周**。

### 建议的开发顺序

1. **第一周**出一个"菜单栏里能看到项目、点击能跑到模拟器"的最粗糙版本——验证核心路径通畅
2. **第二周**补主窗口、日志、错误处理——可用版本
3. **第三周**加真机部署——完整版
4. **第四周**打磨 + 打包

---

## 9. 成功标准

做到以下三点就算成功：

1. 从"改完代码"到"app 在模拟器里跑起来"**不超过 3 次点击**、**0 次键盘输入**
2. Xcode 和 VS Code 都可以不打开
3. 用 7 天后，你发现自己再也不想回去手动开 Xcode 了

---

## 10. 下一步（开发启动前还需决定的）

1. **命名**：`LaunchPad for iOS` 只是占位（Apple 自己的 "Launchpad" 会冲突）。候选：
   - `SimRunner` — 直白
   - `Quickship` — 暗示"快速发射"
   - `Bolt` — 短有力
   - `Pilot` — 驾驶舱感
   - `Runway` — iOS 跑道
   - 其他你想到的？
2. **Xcode 版本兼容**：最低支持哪一版 Xcode？建议 Xcode 15+（`devicectl` 在 15.0 引入）
3. **第一个验证项目**：先拿你现有 3 个项目里结构最简单的那个当白鼠，避免一上来就撞上奇怪的项目配置问题
4. **开发环境本身**：这个项目本身就适合用 Claude Code 来写——Swift + SwiftUI 它写得非常好。我们开写的时候可以用 TDD 的方式：先写 `ProcessRunner`、`XcodeBuildParser` 这些纯函数模块的测试，再组装

准备开干的时候告诉我，可以按 M1 开始搭脚手架，也可以先把 M3 的 Run 流程单独抽出来做一个 20 行的 Swift 脚本原型，验证"用 `Process` 调 xcodebuild 并实时拿到输出"的链路通不通——**强烈建议先做这个原型**，因为整个 app 的成败都押在这个链路上。