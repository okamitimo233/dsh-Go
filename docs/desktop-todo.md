# Linux 桌面端 TODO

> 分支：`desktop-linux-native`。目标：Linux x86_64 上可日常使用，后端从官方 npm 拉取并以宿主机 Node 进程运行，不使用容器。
>
> 当前状态：**P0 的逐帧开销、窗口尺寸、模糊对比、timeline 诊断和构建问题已修复；只剩真实后端下的聊天滚动/抽屉/流式长稳场景基准**。

## P0 阶段记录（2026-11-09）

本机环境：Wayland / Niri，NVIDIA RTX 5070 Ti Laptop（驱动 620.70.06），`glxinfo` 显示 direct rendering，Flutter 走 Impeller OpenGL ES；本次运行没有出现先前日志里的 Mesa Zink / dri2 错误。Niri 输出逻辑缩放 1.5，Flutter 在原生 Wayland 下报告 DPR 2；home 实测窗口为 900×971 逻辑 / 1800×1942 物理，启动表面没有异常放大。

产品决定：桌面端默认不降低画面质量。手机能流畅运行的玻璃模糊和灵动动效在桌面保持开启；性能问题通过消除无意义的逐帧工作、窗口尺寸约束和构建优化解决，而不是默认关闭视觉效果。

已完成的验证和修复：

- 桌面端不再注册 `RefreshRateService` 的逐帧回调，也不再调用不存在的 `dsh/app` 通道；unit test 已覆盖 no-op 行为。
- Linux runner 使用受工作区限制的初始窗口尺寸和最小尺寸。
- `FrameClock` 只调整时间戳，不会申请帧；流式聊天已有 32ms 合并刷新。
- Profile frame probe：完整画质 home 在原生 Wayland、DPR 2、持续 resize 压力下为 57.8 FPS，build p95/p99 3.60/4.53 ms，raster p95/p99 5.66/6.31 ms，jank 0%。关闭玻璃模糊后 raster p95 降到 4.25 ms、帧率 56.8 FPS，说明 blur 有成本但不是当前唯一瓶颈。`RefreshRateService` 已不再出现在逐帧来源中。
- 关闭桌宠后 idle 约 1 帧/5 秒；桌宠可见时约 18 帧/秒来自精灵逐帧动画本身，不是空闲帧调度泄漏。
- 新增 `FrameBudgetWindow`、`tooling/frame_probe_check.py` 和 `tooling/benchmark-linux.sh`，把 FPS、build/raster p95/p99、jank ratio 变成可执行的阈值检查；合成预算测试同时限制 blur/glass/clip/painter 数量。
- 新增 `tooling/capture-timeline.py` 和 `tooling/timeline_stage_check.py`，用 VM timeline 补采 build/layout/paint/compositing；home resize 抓取中 layout p95 3.02 ms、paint p95 0.96 ms、Frame p95 7.35 ms。
- Linux 原生头文件去抖已落地；同一 mode 的热缓存无改动构建约 5.0 秒（修复前约 8–9 秒）。切换 mode/首次 AOT 实测约 45–96 秒，原因和边界见 [desktop.md](desktop.md#构建速度)。

仍需补测：完整聊天长列表滚动、打开抽屉/输入聚焦和流式输出长稳（依赖真实后端会话）。Skia fallback 在 Linux 当前 Flutter 不可切换；GTK 3 的 fractional DPR 是平台限制，原生 Niri 1.5 倍会以 Flutter DPR 2 渲染。

## P0：桌面端性能（当前最高优先级）

### P0.1 性能基线与环境确认

- [x] 区分“应用本身慢”和“当前机器没有可用 GPU”：
  - [x] 记录运行环境：GPU/驱动、Wayland/X11、Mesa 版本、`glxinfo`/`vulkaninfo`、Flutter 渲染后端。
  - 硬件路径和强制 llvmpipe 路径都已运行；llvmpipe 的 resize 压力没有复现 3 FPS。
- [x] 对比三种运行方式：
  - release bundle 正常运行，日志为 Impeller OpenGL ES，无未处理 Dart 异常；
  - profile frame probe 已采集完整画质窗口；
  - Linux 当前 Flutter 忽略 `--no-enable-impeller`，无法得到真实 Skia fallback 结果，已记录为平台限制。
- [x] 确认是否只在软件渲染（llvmpipe）时 3 FPS：强制 llvmpipe 的 onboarding resize 压力约 59.8 FPS，未复现；完整聊天列表的软件渲染仍应作为后续基准补项。
- [x] 用 DevTools Performance / Flutter timeline 抓取：
  - [x] frame probe 已提供 build/raster 耗时、frame budget、持续 ticker/重绘来源和空闲帧调度；
  - [x] `capture-timeline.py` 打开 DevTools 同款 timeline 开关并抓取 build/layout/paint/compositing/Frame；home resize 实测 layout p95 3.02 ms、paint p95 0.96 ms、compositing 0.11 ms、Frame p95 7.35 ms，未发现数量级异常。
- [ ] 记录基准场景：冷启动、会话列表、聊天静态页、滚动、打开抽屉、输入框聚焦、流式回复。
  - 已覆盖：冷启动、home 静态页、持续窗口 resize、1×/2× X11、原生 Wayland DPR 2、idle（有/无桌宠）。
  - 未覆盖：会话列表滚动、输入聚焦、打开抽屉、流式回复长稳。

### P0.2 先排除窗口尺寸/像素比问题

- [x] 首帧日志出现 `1694x1940` 这类大尺寸，远高于 GTK runner 默认 `1280x720`。检查：
  - Wayland 缩放因子和 Flutter DPR；
  - 窗口实际逻辑尺寸与物理像素；
  - 是否被窗口管理器异常拉伸；
  - 是否有超大 `RepaintBoundary`/离屏层。
  - 实测原生 Wayland/Niri 输出 1.5 时 Flutter 报告 DPR 2：900×971 逻辑 / 1800×1942 物理；X11 1×/2× 也已记录。未发现异常拉伸或单页超大离屏层。
- [x] 给 Linux runner 设置合理初始窗口尺寸和最小/默认尺寸，避免首帧就渲染过大的表面。
- [x] 在 1x、1.25x、1.5x、2x 缩放下分别记录 FPS 和 raster 时间。
  - 已记录 1×（X11 DPR 1 onboarding）59 fps、2×（X11 DPR 2 onboarding）约 54 fps，原生 Wayland home DPR 2 约 58 fps。
  - GTK 3 `GDK_SCALE` 只接受整数；X11 下 1.25/1.5 仍报告 DPR 1。原生 Niri 输出 1.5 倍时 Flutter 通过 `gdk_monitor_get_scale_factor` 取整为 DPR 2，并已在该路径实测 home 57.8 FPS。故 1.25/1.5 的 fractional Flutter DPR 在当前 Linux embedder 中不可用，已记录为平台限制而不是漏测。

### P0.3 玻璃模糊与大量合成效果

- [x] 评估桌面性能降级默认值：确认 `DshSurfaces.blurEnabled` 能让桌面走不透明 fallback，但按产品决定默认保持玻璃模糊开启。
- [x] 统计首屏同时存在的 `BackdropFilter`、`BackdropGroup`、clip、shadow、custom painter 数量（1280×800 普通会话约 7 blur / 2 group / 9 glass / 14 clip / 33 CustomPaint；自动测试设 8/3/10/20/45 上限）。
- [x] 对比测试：
  - [x] `DSH_UI_NO_BLUR` 构建下 composition test 验证 blur 数为 0；
  - [x] home 设置关闭玻璃模糊后实测 56.8 FPS，raster p95 4.25 ms（完整画质 57.8 FPS / 5.66 ms）；
  - [x] 关闭 blur 的 home 仍通过 50 FPS、p95 8 ms、jank 2% 回归阈值。
- [x] 是否把 blur 设为桌面默认策略：评估后不采用；桌面保持完整画质，轻量模式由用户手动选择。

### P0.4 持续动画和重绘

- [x] 检查所有无限动画：鲸尾、桌宠、背景、流式光标、活动状态、动画渐变、自定义 `Ticker`。
- [x] 检查 `TickerMode` 是否在不可见页面正确停止动画。
- [x] 检查 `FrameClock`/`SteadyFrameBinding` 是否只是调时间，还是间接导致持续调度帧；确认空闲时应用是否持续申请帧。
- [x] 检查 `RefreshRateService` 在桌面缺少 `dsh/app` 通道时是否产生额外异常/定时器；桌面应直接 no-op。
- [x] 为静态区域增加 `RepaintBoundary`，避免整页因小动画重绘：聊天行、状态点、输入指示点、进度光环和抽屉 skeleton 均已隔离。
- [x] 对流式聊天和工具输出做批量刷新，避免每个事件都触发整棵聊天树布局。

### P0.5 桌面性能档位

- [x] 给桌面明确性能档位：
  - 自动档不降低桌面视觉质量，玻璃和灵动动效保持开启；
  - 轻量档由用户手动选择；
  - 刷新率策略使用系统值；
  - 不按手机低端机策略误判。
- [x] 在设置中保留“高质量视觉效果”开关，用户可以手动恢复玻璃和动效。
- [x] 加入性能回归验证：`DSH_FRAME_PROBE` 输出 FrameTiming 百分位和 jank ratio，`frame_probe_check.py` 可设置 FPS/frame-budget/raster 阈值；home 已按 50 FPS、p95 8 ms、jank 2% 的阈值通过，composition budget 测试已加入测试套件。

## P1：本地后端完整闭环

- [ ] 在 GUI 中完整走一遍：首次安装 → npm 安装完成 → 启动引擎 → 解析 token → 连接 → 配置模型 → 新建会话 → 发送消息 → 收到流式回复。
- [ ] 验证官方 npm 包安装失败、Node/npm 不存在、网络中断、npm registry 不可达时的错误提示。
- [ ] 验证 `DSH_GO_NODE`、`DSH_GO_NPM`、nvm/fnm/volta 路径查找。
- [ ] 验证停止、重启、App 退出后残留进程清理、stale PID 清理。
- [ ] 验证 `dsh web` 只监听 `127.0.0.1`，token 不进入日志、不持久化。
- [ ] 验证 DSH 版本升级/不匹配时重新安装流程。
- [ ] 把桌面安装页文案从“解压运行环境”改成“从 npm 安装 DSH”，避免用户误解。
- [ ] 给桌面后端进程管理增加可测试的进程启动器/状态机单元测试。

## P1：手机端功能裁切收尾

- [ ] 逐项人工检查桌面 UI，确保以下入口不出现或不会崩溃：
  - 手机操控、无障碍、Droid 权限页；
  - Android 后台保活；
  - 系统通知/Live Activity；
  - 系统语音识别；
  - 悬浮桌宠、桌宠设置；
  - App 图标、快捷方式、启动动画；
  - APK 应用内更新；
  - 相机扫码；
  - 嵌入式网页模式。
- [ ] 检查设置搜索、全部功能、快捷入口、深链 `dshgo://`、通知跳转是否仍能进入已裁切页面。
- [ ] 检查 Android 专属 MethodChannel 在桌面缺失时只产生可读的“不支持”状态，不产生未处理异常。
- [ ] 检查 Linux 下 WebView 页面的系统浏览器兜底和返回行为。
- [ ] 检查扫码配对页的“从图片导入/粘贴”兜底是否足够，或明确显示桌面不支持。
- [ ] 为桌面端平台能力判断补单元测试，明确测试环境和真实桌面不能混淆。

## P1：验证与 CI

- [ ] 完整跑一遍 `flutter test`（当前只跑了相关测试；全量测试因单次命令超时未跑完）。
- [ ] 检查新增 Linux CI job 在 GitHub runner 上通过：
  - `flutter pub get --enforce-lockfile`
  - `flutter build linux --release`
  - GTK/CMake/Clang/libsecret 依赖完整。
- [ ] 增加桌面 smoke test：启动 release bundle 后进程存活、无未处理 Dart 异常。
- [ ] 确认 `flutter_webrtc` 的 Linux 预编译库下载在 CI 和普通用户网络下都可复现。
- [ ] 验证窗口缩放、最大化、多显示器、键盘 Enter/Shift+Enter、剪贴板、文件选择、系统浏览器。

## P2：接近 Android 功能完整度

- [ ] 评估官方 npm 版 DSH 与 Android runtime 的差异：`runtime/patches/*.diff`、`dsh-go-bridge`。
- [ ] 决定桌面是否复用同一套补丁和 bridge：
  - 若需要插件配置、原生插件协议、会话永久删除、伙伴小屋服务端状态等，应接入 `dsh-go-bridge`。
  - 保持官方 npm 安装路径时，可另加本地 bridge 包/`--patch` overlay，不引入容器。
- [ ] 评估把 `dsh-go-ui`、`dsh-go-plugin`、`dsh-go-guide`、`dsh-go-support` 技能写入桌面 DSH_HOME。
- [ ] 评估桌面 UI 配置 `ui.json` 的读取/监听：当前本地 rootfs 路径逻辑不适用于桌面。
- [ ] 评估内置 Node/DSH 运行时，降低对用户系统 Node/npm 的依赖；仍直接运行宿主机进程，不用容器。
- [ ] 评估 Linux 发行包：AppImage/deb/tar、`.desktop` 文件、图标和卸载说明。
- [ ] 评估 Windows/macOS 后续路径，但本阶段不展开。

## 已知边界（当前交付说明）

- [ ] 首版使用官方未打补丁的 DSH npm 包，没有 Android runtime 的补丁和 bridge。
- [ ] 依赖 `dsh-go-bridge` 的原生插件协议、完整插件配置、会话永久删除、伙伴小屋服务端状态等可能降级或不可用。
- [ ] 桌面运行时依赖宿主机 Node.js >= 20 和 npm。
- [ ] 未验证真实 GPU、不同桌面环境、不同缩放、Windows/macOS。
