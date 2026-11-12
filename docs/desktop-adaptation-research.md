# Flutter 桌面端适配与无容器后端调研

> 2026-11-08。本文基于仓库当前代码的静态调研，目标是为“把现有 Flutter UI 适配为桌面端构建，并在不使用容器的情况下运行后端”给出可行性判断和实施路线。
>
> 当前环境未安装 Flutter/Dart，因此本文尚未执行 `flutter analyze`、`flutter test` 或桌面构建；相关结论需在接入桌面 runner 后复核。

## 0. 结论

**可行，但不能把当前工程简单 `flutter create` 出桌面目录就结束。**

这个仓库是 **Android 优先的 Flutter 应用**：

- Flutter UI、Riverpod 状态、`packages/dsh_client` 和 `packages/dsh_remote` 的复用价值很高；
- 本地引擎的安装、运行、日志、token 和进程管理全部在 Android Kotlin 层，通过 `dsh/runtime` 等 MethodChannel 暴露；
- 另有一批手机系统能力（手机操控、通知、悬浮桌宠、语音、图标、APK 更新、WebView 等）没有桌面实现。

后端不使用容器是合理的：DSH 本身就是 Node.js 服务，桌面端可以直接以**宿主机 Node 进程**运行 `dsh web`，既不需要 Docker，也不需要 PRoot。建议 **Linux x86_64 先行**。

## 1. 当前架构

| 模块 | 现状 | 桌面复用性 |
|---|---|---|
| `app/` | Flutter UI + Riverpod，约 950 个 Dart 文件 | 高，但平台层要拆 |
| `app/android/.../runtime/` | 解压 Ubuntu rootfs、PRoot 启动 `dsh web`、前台服务、安全模式、日志、进程识别 | 不可直接复用 |
| `packages/dsh_client/` | 纯 Dart HTTP/WebSocket 客户端 | 可直接复用 |
| `packages/dsh_remote/` | 纯 Dart Relay/Noise，WebRTC 通过注入 | 大部分可复用 |
| `runtime/` | 打补丁的 DSH、`dsh-go-bridge`、PRoot rootfs 构建 | 补丁和 bridge 可复用，构建脚本要改造 |
| `services/share-worker/` | Cloudflare Worker，本身无容器 | 已是无容器方案 |
| `infra/forum/` | 可选 Discourse Docker 部署 | 与 App 核心无关；要无容器需自行维护 Discourse/PG/Redis |

关键文件：

- `app/lib/runtime/runtime_bridge.dart`：本地运行时的 MethodChannel/EventChannel 客户端
- `app/lib/runtime/runtime_state.dart`：UI 使用的运行时状态
- `app/lib/ui/shell/root_gate.dart`：首启判断强依赖“本机运行时”状态
- `app/lib/state/connection_state.dart`：本地连接从 `RuntimeStatus.baseUrl + token` 建立
- `app/lib/ui/web/web_view_page.dart`：嵌入式 DSH Web
- `app/android/.../runtime/DshProcess.kt`：Android 进程启动核心
- `app/android/.../runtime/RuntimePlugin.kt`：Dart 与 Kotlin 的通道协议
- `runtime/build-runtime.sh` 与 `runtime/lib/rtbuild.py`：DSH 安装、打补丁、bridge 和 rootfs 组装
- `app/lib/remote/ssh/remote_bootstrap.dart`：已包含“启动并解析 `dsh web` token”的成熟逻辑，可借鉴

## 2. 桌面端主要阻塞点

### 2.1 工程层面

`app/` 目前只有：

- `app/android/`
- `app/lib/`
- `app/test/`

没有 `linux/`、`windows/`、`macos/` runner。`.metadata` 也只登记了 Android。

### 2.2 本地运行时是硬阻塞

`runtimeBridgeProvider` 的 `status()`、`start()`、`install()` 等默认调用 Android `dsh/runtime` 通道。虽然部分读取失败会回退，但：

- `RootGate` 会把未知状态当作 `notInstalled`；
- 首启会进入“本机安装环境 / 远程主机”选择；
- 选择“本机”后会调用不存在的安装通道，无法真正启动后端。

因此桌面端不能只靠缺失插件时“自然失败”，必须增加桌面实现或明确禁用本机运行时。

### 2.3 平台插件支持情况

已核对 `pubspec.lock` 和 pub.dev 当前平台声明：

| 依赖 | 桌面支持 | 备注 |
|---|---|---|
| `shared_preferences` | Linux/Windows/macOS | 直接可用 |
| `path_provider` | Linux/Windows/macOS | 直接可用 |
| `flutter_secure_storage` | Linux/Windows/macOS | Linux 需要系统 keyring/libsecret |
| `url_launcher` | Linux/Windows/macOS | 直接可用 |
| `share_plus` | Linux/Windows/macOS | 直接可用 |
| `file_picker` | Linux/Windows/macOS | 直接可用 |
| `image_picker` | Linux/Windows/macOS | 选图可用，摄像头行为不同 |
| `connectivity_plus` | Linux/Windows/macOS | 可用 |
| `dartssh2` | 纯 Dart | 可用 |
| `flutter_webrtc` | Linux/Windows/macOS | 可用，但需逐平台验证 |
| `webview_flutter` | Android/iOS/macOS | **Linux/Windows 无实现** |
| `webview_flutter_android` | Android | 只能条件使用 |
| `mobile_scanner` | Android/iOS/macOS/Web | **Linux/Windows 无实现** |

`webview_flutter` 在 macOS 有 `webview_flutter_wkwebview`；Linux/Windows 需要换成外部浏览器、另选 WebView 插件，或暂时禁用网页模式。

### 2.4 Android 专属能力

大约 20 多个自定义 MethodChannel，主要集中在：

- `dsh/runtime`：本地引擎
- `dsh/phone`：手机操控、无障碍、屏幕读取
- `dsh/media`、`dsh/media_video`、`dsh/native-media`：相册、媒体、摄像头
- `dsh/files`、`dsh/native-files`、`dsh/web-files`：Android 文件选择
- `dsh/notify`：系统通知、通知点击、实时活动
- `dsh/voice`：系统语音识别
- `dsh/pet_overlay`、`dsh/companion_widget`、`dsh/companion_voice`：悬浮桌宠、小组件、语音
- `dsh/islands`：Android WebView 面板
- `dsh/share`、`dsh/links`、`dsh/shortcuts`：Android 分享/深链/快捷方式
- `dsh/update`：APK 更新
- `dsh/dynamic_color`、`dsh/launcher_icon`、`dsh/picture_shortcut`：Android 外观和图标
- `dsh/performance`、`dsh/diagnostics`、`dsh/app`：部分可用，部分只能回退

其中不少代码已经能容忍 `MissingPluginException`，例如通知、桌宠、动态取色、诊断等；但**运行时、手机操控、WebView、扫码、更新安装**不能只靠回退。

### 2.5 UI 本身反而比较乐观

- 主题、聊天、会话、抽屉、自适应布局、宽屏侧栏都已经有测试；
- 大量 widget test 在 Linux CI 上运行，说明 UI 逻辑本身没有强依赖 Android 渲染；
- 桌面端没有系统安全区，`MediaQuery` 通常为 0，现有宽屏布局应该能工作；
- 硬件键盘 Enter 已有 `hardwareEnterSends` 逻辑。

## 3. 后端“不使用容器”的方案

### 先明确两点

1. 当前 Android 本机引擎用的是 **PRoot + Ubuntu rootfs**，不是 Docker，但本质上是容器式用户态环境；
2. 桌面端运行 `dsh web` **不需要 PRoot**，直接启动宿主机 Node 即可。

### DSH 版本不能随便用 stock npm 包

仓库维护的是：

- 固定版本 `DSH 0.2.2-rc.1`
- `runtime/patches/*.diff` 大量安全、稳定性、会话、插件、文件、Unicode 修复
- `dsh-go-bridge` 提供 App 专属接口：
  - `/dsh-go/v1/inventory`
  - 原生插件 contributions/views/invoke/stream
  - 插件配置
  - 会话永久删除
  - 伙伴小屋
  - 文件选择/上传
  - route guard 等

所以：

- **只装官方 `@deepseek-ai/dsh`**：聊天核心大概率可用，但插件页、宿主渲染插件、插件配置、会话删除、伙伴等会降级或不可用；
- **要接近现有功能**：需要复用同一套打补丁 DSH + `dsh-go-bridge`。

### 推荐三级路线

#### 方案 A：仅远程主机，最快验证 UI

不实现桌面本机运行时，桌面 UI 只连接：

- SSH 主机
- DSH Remote/Relay

优点：

- 现有 `SshHostLink`、`RemoteDshBootstrap`、`DshClient` 都能复用；
- 不需要处理本地 Node 安装和进程生命周期；
- 可以最快在 Linux 桌面跑通聊天、会话、设置和大部分 UI。

适合先在 1–2 周内验证“桌面 UI 到底能不能用”。

#### 方案 B：App 管理宿主机上的 `dsh web`，推荐 MVP

在 Dart 侧新增一个桌面本地运行时后端，和 Android 的 `RuntimeBridge` 提供同样的状态/事件语义：

```text
DesktopLocalRuntime
  启动: Process.start('dsh', ['web', '--host', '127.0.0.1', '--port', '0', '--no-open'])
  监听 stdout/stderr
  解析: DshLaunchUrl.tryParse(...)
  发布: phase = running, baseUrl, token
  停止: 精确结束进程/进程组，不误杀其他 dsh
```

可直接借鉴：

- `packages/dsh_client/lib/src/connection.dart` 里的 `DshLaunchUrl.tryParse`
- `app/lib/remote/ssh/remote_bootstrap.dart` 的启动脚本、token 解析和状态设计
- `app/lib/remote/ssh/remote_shell.dart` 的 `LocalProcessShell`

需要补齐：

- 动态端口、日志缓冲、状态事件、安装/未安装状态
- 进程组管理、退出分类、自动重启、残留进程检测
- token 只保存在内存，不写日志
- 后端只监听 `127.0.0.1`
- 退出 App 时默认停止后端，或明确提供“后台继续运行”
- 数据目录和 `DSH_HOME` 放到桌面应用数据目录，不要沿用 Android 的 `/root`
- 本机主机仍复用 `HostKind.local`，`LocalConnectionController` 基本不需要重写

这样桌面端仍然是“无容器”的：后端就是一个普通 Node 子进程。

**此方案的依赖前提**：用户机器上已安装 Node 和 DSH。可以先用这个做开发版，再决定是否内置运行时。

#### 方案 C：桌面端自带固定版本的原生 DSH 运行时

长期方案，功能最完整：

- 从 `runtime/build-runtime.sh` 抽出 DSH 安装/打补丁/bridge 安装逻辑；
- 新增 `runtime/build-desktop.sh`，产出 Linux x64 的 host-native 运行时；
- 不再生产 rootfs 和 PRoot；
- 可以：
  - 依赖宿主机 Node，或者
  - 将 Node 24.22.1 和打补丁后的 DSH 一起放进应用资源/安装包；
- 用 `runtime/lib/rtbuild.py patch-dsh` 保持补丁与 `pins.json` 一致；
- 通过本地 `--patch` 文件加载 `dsh-go-bridge`，与 Android 运行时保持同源；
- Windows/macOS 再分别做平台适配，不建议第一版同时铺开。

安全上要明确：桌面本机引擎拥有当前用户权限，能执行真实命令，所以默认权限策略、确认机制和日志脱敏不能因为脱离 Android 而放松。

## 4. 建议的实施顺序

### 阶段 0：桌面壳和平台能力拆分

1. 在 `app/` 执行：

   ```bash
   flutter create --platforms=linux .
   ```

2. 增加平台能力抽象，例如：

   - `LocalRuntimeHost`
   - `AndroidNativeRuntimeHost`
   - `DesktopProcessRuntimeHost`
   - `UnavailableRuntimeHost`

3. `RootGate` 根据平台能力决定是否显示“安装本机运行环境”。
4. 条件禁用/隐藏 Android 专属功能：

   - 手机操控
   - 桌宠悬浮
   - 图标/动态取色
   - APK 更新
   - 系统语音
   - 扫码

5. WebView 在 Linux/Windows 改为外部浏览器，macOS 可保留原生 WebView；扫码改为从图片导入。
6. 运行：

   ```bash
   cd app
   flutter pub get
   flutter analyze
   flutter test
   flutter build linux
   ```

### 阶段 1：远程连接桌面客户端

先让 UI 通过 SSH/Relay 连真实 DSH，验证：

- 会话列表、聊天、附件、工具审批
- 终端、文件、设置、插件接口
- 窗口缩放、宽屏布局、键盘输入

这是判断 UI 适配质量的最短闭环。

### 阶段 2：桌面本机 DSH 进程管理

实现方案 B，并补齐：

- 本地引擎设置页
- 启动/停止/重启
- 引擎日志
- 首次配置（用户安装 DSH 或指定 `dsh` 路径）
- 自动启动
- 断线和异常退出恢复

### 阶段 3：内置打补丁运行时

实现方案 C，达到功能与 Android 尽量一致，再考虑 Windows/macOS。

## 5. 需要确认的产品问题

在动手前建议先定三件事：

1. **第一目标平台**：建议 Linux x86_64；Windows/macOS 是继续做还是只做远程客户端？
2. **后端由谁提供**：用户自己安装 `dsh`，还是桌面应用内置固定版本？
3. **功能边界**：桌面端是否必须保留手机操控、桌宠、网页模式、扫码、APK 式更新，还是首版只保证聊天和主机连接？

建议路线：**Linux-first + 远程模式先跑通 + 桌面本机 Node 进程作为第二阶段，不移植 PRoot，也不引入 Docker。**
