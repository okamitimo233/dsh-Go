# Linux 桌面端

> 目标平台：Linux x86_64。后端直接以宿主机 Node 进程运行，不使用 Docker、PRoot 或其他容器。

## 当前已实现

- 复用现有 Flutter 原生界面、Riverpod 状态、`packages/dsh_client` 和 `packages/dsh_remote`。
- 新增 Linux runner：`app/linux/`。
- 新增桌面本地运行时：`app/lib/runtime/desktop_runtime_bridge.dart`。
  - 首次安装时通过官方 npm registry 安装固定版本的 `@deepseek-ai/dsh`；
  - 用宿主机 Node 启动 `dsh web --host 127.0.0.1 --port 0 --no-open`；
  - 从 stdout 解析 launch token，沿用现有本地连接和聊天 UI；
  - 不安装 Ubuntu rootfs，不使用 PRoot。
- 桌面端隐藏或替换手机专属入口：手机操控、Android 权限页、后台保活、系统通知、系统语音、悬浮桌宠、桌面图标、启动动画、应用内 APK 更新等。
- Linux 下没有 `webview_flutter` 实现：网页入口改为系统浏览器打开；网页模式不作为桌面首页。
- Linux 下没有相机扫码实现：扫码配对页显示不可用，不再创建相机控制器。

## 依赖

构建：

- Flutter 3.47.7
- clang、cmake、ninja、pkg-config
- GTK 3 开发头文件

运行时：

- Node.js >= 20
- npm

首次运行会把 DSH 安装到应用数据目录，并通过 XDG 路径保存配置，例如：

```text
$XDG_DATA_HOME/dsh_app/dsh-engine/      # npm prefix
$XDG_DATA_HOME/dsh_app/dsh-home/        # DSH_HOME
$XDG_DATA_HOME/dsh_app/workspace/       # dsh web 的启动工作目录
```

如果 `node` 或 `npm` 不在启动应用的 PATH 中，安装会失败并在引擎日志里给出原因。使用 nvm/fnm 的用户建议从已经加载 shell 环境的终端启动，或把 Node 放到 `/usr/local/bin`。

## 性能策略

桌面端默认保持与手机完整档一致的视觉质量：玻璃模糊和灵动动效照常开启，不因为运行在桌面而自动降级。设置 → 性能仍提供「轻量」，以及单独的「玻璃模糊」「界面动效」「灵动动效」开关，用户需要时再手动减少效果。

桌面不注册 Android 的 `dsh/app` 刷新率通道，帧率控制交给 compositor，因此设置页不显示刷新率选项；桌面端也不会保留一个对每帧产生额外调用的 `RefreshRateService` 监听器。

### 帧预算探针与回归检查

`DSH_FRAME_PROBE` 是只在 debug/profile 构建中生效的 opt-in 诊断。它不主动申请帧，按 5 秒窗口输出：

- 逻辑/物理尺寸、DPR、显示器刷新率；
- `FrameTiming` 的 build/raster/total span p50、p95、p99、max；
- 超过预算的帧数、jank 比例、实际绘制帧率；
- 持续 ticker、Timer 和帧请求的调用来源。

单个窗口跑基准并检查阈值：

```bash
tooling/benchmark-linux.sh --seconds 20 --require-active \
  --min-frames 240 --max-p95-ms 8 --max-p99-ms 20 \
  --max-jank-ratio 0.02 --min-fps 50
```

脚本默认跳过第一个 5 秒预热窗口，再校验剩余的完整窗口；`--max-windows 1` 可只检查一个稳定窗口。没有进行交互的 idle 运行会因为没有活跃窗口而失败，除非去掉 `--require-active`。探针日志可以直接交给 `tooling/frame_probe_check.py`，它也可作为 CI/基准机上的纯文本阈值检查器。建议用 `GDK_SCALE=…` 或 Wayland 输出缩放做多 DPR 对比；GTK 3 的 `GDK_SCALE` 只接受整数，X11 下 1.25/1.5 实际仍报告 DPR 1，不能当成真实的 fractional-DPR 结果。

2026-11-09 在 RTX 5070 Ti Laptop / NVIDIA 620.70.06 / Wayland + Niri 上、完整画质的实测（首个预热窗口已跳过；持续改变窗口宽度制造布局/paint 压力）：

| 场景 | 帧数/5s | FPS | build p95 / p99 | raster p95 / p99 | jank |
|---|---:|---:|---:|---:|---:|
| 原生 Wayland **home**，900×971 逻辑，DPR 2 | 289 | 57.8 | 3.60 / 4.53 ms | 5.66 / 6.31 ms | 0% |
| 原生 Wayland **home + 关闭玻璃模糊**，DPR 2 | 284 | 56.8 | 3.65 / 3.99 ms | 4.25 / 5.52 ms | 0% |
| X11 onboarding，DPR 1 | 294 | 58.8 | 0.65 / 0.79 ms | 2.18 / 4.08 ms | 0% |
| X11 onboarding，DPR 2（`GDK_SCALE=2`） | 272 | 54.4 | 0.68 / 0.83 ms | 3.58 / 5.07 ms | 0% |
| X11 onboarding + 强制 llvmpipe | 299 | 59.8 | 0.76 / 0.98 ms | 3.91 / 4.65 ms | 0% |

- 原生 Wayland 的窗口由 Niri 设为逻辑 1.5 倍输出，Flutter 报告 DPR 2、物理尺寸 1800×1942；这是实际桌面渲染路径的结果。
- 在同一个 home 页面关闭玻璃模糊后，raster p95 从 5.66 ms 降到 4.25 ms，帧率基本不变（56.8 对 57.8 FPS）；当前瓶颈不是「单个 blur 必然拖垮整页」，同屏数量和合成层级才是需要守住的部分。
- X11 的三轮都是 onboarding 页面；它们证明缩放/软件渲染路径本身不必然 3 FPS，但不等同于完整聊天列表/玻璃密集页面的基准。
- 关闭桌宠后 idle 窗口约 1 帧/5 秒；桌宠可见时约 18 帧/秒是精灵帧动画本身，不是 `RefreshRateService` 或 `FrameClock` 泄漏。
- `flutter build linux --release` 产物启动正常，日志继续使用 Impeller OpenGLES，没有未处理 Dart 异常。
- release/profile 均已构建通过。Linux 当前 Flutter 会忽略 `--no-enable-impeller`，日志仍使用 Impeller，因此没有可用的 Skia fallback 对比。

需要 layout/paint 分阶段数据时，可在 profile 进程运行时抓 VM timeline：

```bash
app/build/linux/x64/profile/bundle/dsh_app > /tmp/dsh-profile.log 2>&1 &
python3 tooling/capture-timeline.py --log /tmp/dsh-profile.log \
  --output /tmp/dsh-timeline.json --seconds 8
python3 tooling/timeline_stage_check.py /tmp/dsh-timeline.json \
  --max-p95 'LAYOUT (root)=4' --max-p95 'PAINT (root)=8'
```

`capture-timeline.py` 会打开与 DevTools 相同的 build/layout/paint timeline 开关并抓取 ring buffer；`timeline_stage_check.py` 汇总 `BUILD`、`LAYOUT (root)`、`PAINT (root)`、`COMPOSITING`、`SEMANTICS` 和总 `Frame` 的 p50/p95/p99/max。home + 持续 resize 的一次抓取为：build p95 2.39 ms，layout p95 3.02 ms，paint p95 0.96 ms，compositing p95 0.11 ms，Frame p95 7.35 ms（ring buffer 只保留有限帧，数值用于发现数量级异常，长稳仍以 5 秒 frame probe 窗口为准）。

聊天页面的合成预算由 `app/test/performance/composition_budget_test.dart` 守护。1280×800 下普通会话同屏实测约 7 个 `BackdropFilter`、2 个 `BackdropGroup`、9 个 `GlassSurface`、14 个 clip、33 个 `CustomPaint`；流式会话约 7 个 blur、8 个 glass、29 个 `CustomPaint`。测试的硬上限为 8 / 3 / 10 / 20 / 45，并使用 `DSH_UI_NO_BLUR` 验证 fallback 构建中 blur 数为 0。每个可见聊天行和若干行内动画另有 `RepaintBoundary`，避免流式光标或状态点让整页重绘。

## 构建速度

Flutter 的 Linux 模板每次都会重新运行 `tool_backend.sh`，并把引擎头文件写回 `linux/flutter/ephemeral/flutter_linux/`。即使内容没变，新 mtime 也会让 Ninja 认为所有原生插件和 runner 的 C++ 依赖过期，于是每次只改 Dart 也要重编译全部 Linux 插件。

`app/linux/flutter/stable_tool_backend.sh` 会记住上一份引擎头文件：内容相同就恢复旧 mtime，内容变化才更新时间并触发必要重编译。当前仓库在 16 核机器上的实测：

- 无源码改动、同一 build mode、Dart/pub/AOT 缓存命中：约 5.0 秒；修复前即使只改 Dart 也会重编译全部 27 个 Linux 原生目标，约 8–9 秒；
- 刚才从 profile 切到 release，首次 release AOT 约 95.6 秒；紧接着的第二次仍是 AOT 缓存未完全稳定，约 44.7 秒；第三次无改动降到 5.0 秒；
- 完全冷启动、切换 build mode 或改变 `--dart-define` 会做一次单线程 Dart 前端/AOT，常见为约 45–100 秒；
- 重建 `build/linux/` 但保留 `.dart_tool/` 时，原生部分约 8–9 秒。

因此，头文件去抖解决的是“每次都被迫重编译全部 C++”的问题；Dart AOT 缓存没命中时的几十秒仍不可避免。日常调 UI 建议用 `flutter run -d linux` 和 hot reload，并保持同一个 build mode / define；发布包再用 release 构建。

## 构建与运行

```bash
cd app
flutter pub get --enforce-lockfile
flutter build linux --release
./build/linux/x64/release/bundle/dsh_app
```

也可以使用：

```bash
tooling/build-linux.sh
```

首次启动进入「本机运行时」安装页，点击安装后等待 npm 完成；然后启动引擎并配置模型。

默认安装版本与 `runtime/build-runtime.sh` 的 DSH 版本一致。需要试别的官方版本时：

```bash
flutter build linux --release --dart-define=DSH_DESKTOP_VERSION=<version>
```

## 首版边界

桌面首版从官方 npm 拉取 DSH，不包含仓库 Android runtime 中的 `runtime/patches/*.diff` 和 `dsh-go-bridge`。因此：

- 核心聊天、会话、模型、SSH 和 Relay 连接走现有客户端；
- 依赖 `dsh-go-bridge` 的能力（原生插件协议、插件配置完整表单、会话永久删除、伙伴小屋服务端状态等）可能降级或不可用；
- 桌面暂不实现手机操控、系统通知、悬浮桌宠、系统语音、相机扫码等 Android 专属功能。

后续若要接近 Android 功能完整度，可在桌面构建时复用 `runtime/patches` 和 `dsh-go-bridge`，仍然保持宿主机 Node 进程、不引入容器。

## 后续工作

性能、后端闭环、功能裁切和发布事项见 [desktop-todo.md](desktop-todo.md)。
