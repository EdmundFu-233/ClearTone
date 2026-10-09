# 澄音 ClearTone（Windows / Qt）

ClearTone 的 Windows 桌面版，**Qt 6 Widgets + C++20（CMake）**，功能与 macOS 版对齐：
发现/每日推荐、搜索（联想/热搜/历史/分页）、歌单/专辑/歌手详情、排行榜、电台、
私人 FM、我的音乐/喜欢的音乐/本地音乐/最近播放、评论、消息、个人资料
（等级/听歌排行/签到/收藏计数）、设置、二维码登录、播放队列、播放栏与全屏正在
播放页（YRC 逐字歌词、翻译/音译、偏移调节）、音质菜单与单曲音质覆盖、倍速菜单、
睡眠定时、音频缓存、动态背景。

网易云接入与 macOS 版**共用同一份**本地 Node.js 辅助进程
（`ClearTone/Resources/HelperRuntime/api`）：仅监听 `127.0.0.1`、随机端口 +
一次性 token（`X-CT-Token`）、Cookie 走 `X-CT-Cookie` 头、主进程退出时跟随退出。
Windows 侧只额外携带 win-x64 / win-arm64 的 `node.exe`。

> 旧版 .NET 8 + Avalonia 实现已于 2026-10 整体替换（旧实现见 git 历史）；
> C# → C++ 的逐条映射约定见 [CONVENTIONS.md](CONVENTIONS.md)。

## 一键编译

### Windows

前置：

- **Visual Studio 2022**（“使用 C++ 的桌面开发”工作负载；要交叉编译 ARM64 还需要
  “MSVC v143 - VS 2022 C++ ARM64 生成工具”）；
- **CMake ≥ 3.24**（VS 自带即可）；
- **Qt 6.5+**（Qt Online Installer 勾选 `MSVC 2022 64-bit`，做 ARM64 包则同时勾选
  `MSVC 2022 ARM64`；**并勾选 Qt Multimedia / Qt Shader Tools**，否则没有音频后端）；
  也可以用 `aqtinstall`：
  `aqt install-qt windows desktop 6.8.3 win64_msvc2022_64 -m qtmultimedia qtshadertools`、
  `aqt install-qt windows desktop 6.8.3 win64_msvc2022_arm64_cross_compiled -m qtmultimedia qtshadertools`；
- **Node.js**（仅开发机需要，用于 `npm ci` 装辅助进程依赖；应用运行不依赖系统 Node）。

```powershell
cd windows

# Debug 构建，完成后直接运行（Qt 自动探测；也可加 -QtRoot C:\Qt\6.8.3\msvc2022_64）
powershell -ExecutionPolicy Bypass -File build.ps1 -Run

# 构建并运行全部离线单测
powershell -ExecutionPolicy Bypass -File build.ps1 -Tests

# win-arm64 Release 发布包（zip，含 Qt 运行库与 helper）
# 在 ARM64 Windows 上直接构建；在 x64 Windows 上交叉编译需同时提供主机 Qt
powershell -ExecutionPolicy Bypass -File build.ps1 -Arch arm64 -Release -Package `
  -QtRoot C:\Qt\6.8.3\msvc2022_arm64 -QtHostPath C:\Qt\6.8.3\msvc2022_64
```

脚本会自动：准备 `runtime\win-<arch>\node.exe` → 缺 `api\node_modules` 时执行
`npm ci --omit=dev --ignore-scripts` → CMake 配置/构建 →（可选）跑测试 / 运行 / 打包。

### macOS / Linux（开发自测）

```bash
brew install qt cmake

cd windows
./build.sh            # 构建（Debug，构建目录 build/）
./build.sh --run      # 构建并运行（macOS 上音频走 Qt Multimedia）
./build.sh --tests    # 构建并运行全部离线单测
./build.sh --clean --release
```

首次运行前如果 `ClearTone/Resources/HelperRuntime` 缺 Node 或依赖，`build.sh`
会自动调用仓库根目录的 `scripts/setup-helper.sh`。

### 脚本参数

| `build.ps1` | `build.sh` | 说明 |
| --- | --- | --- |
| `-Arch x64\|arm64` | — | 目标架构（默认取本机；arm64 交叉编译需对应 Qt 包与 VS ARM64 工具链） |
| `-QtRoot PATH` | `--qt PATH` | Qt 安装前缀（默认自动探测 `C:\Qt\*` / `brew --prefix qt`） |
| `-QtHostPath PATH` | — | ARM64 交叉编译时指向 x64 主机 Qt（提供 moc/rcc/windeployqt；默认自动探测） |
| `-Release` | `--release` | Release 构建（默认 Debug） |
| `-Tests` | `--tests` | 构建后运行全部离线单测（ctest） |
| `-Run` | `--run` | 构建后运行应用 |
| `-Package` | — | 走 `scripts\build-app.ps1` 打 Release 发布 zip |
| `-VlcRoot PATH` | `--vlc-root PATH` | 可选：libVLC SDK 根（含 `include\` / `lib\`）；缺省用 Qt Multimedia |
| `-Generator NAME` | — | 构建生成器（默认 `Visual Studio 17 2022`；ARM64 交叉或 CI 环境可用 `Ninja`，需先进入 VS 开发者环境） |
| `-Clean` | `--clean` | 先清空构建目录 |
| `-BuildDir PATH` | `--dir PATH` | 构建目录 |
| `-SkipHelper` | `--skip-helper` | 跳过辅助进程准备 |

## 测试

```bash
# macOS / Linux
./build.sh --tests
# 等价于
./scripts/run-tests.sh

# Windows
powershell -ExecutionPolicy Bypass -File build.ps1 -Tests
# 或
powershell -ExecutionPolicy Bypass -File scripts\run-tests.ps1
```

20 个 Qt Test 可执行（包含界面布局回归），全部离线（桩 provider / 桩音频引擎），
持久化由 CTest 逐用例重定向到临时目录。离线测试只能证明本地实现与接口约定一致，
真实账号登录、在线播放与上游接口可用性需要实机验证。

## 发布打包（Windows）

一键脚本（推荐）：

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1 -Arch all -Release -Package `
  -QtRoot C:\Qt\6.8.3\msvc2022_64
```

等价的手动流程：

```powershell
# x64 / arm64 / all；-VlcRoot 可选
powershell -ExecutionPolicy Bypass -File scripts\build-app.ps1 -Arch arm64 `
  -QtRoot C:\Qt\6.8.3\msvc2022_arm64
```

产物：

- `publish\win-<arch>\`：`ClearTone.exe` + `windeployqt` 部署的 Qt 运行库 +
  `helper\bin\node.exe` + `helper\api\`（业务代码与依赖）；
- `publish\ClearTone-win-<arch>.zip`：可直接分发，解压后运行 `ClearTone.exe`。

说明：

- Qt 无法从 macOS 交叉发布 Windows 产物，打包必须在 Windows 上执行；
- 默认使用 Qt Multimedia 音频后端（Windows Media Foundation 解码）；提供
  `-VlcRoot` 时链接并打包 libVLC（与旧版行为一致）；
- 当前未做安装器（MSI/Inno Setup）与代码签名；zip 解压即用，SmartScreen 可能提示。

## 本地数据

| 内容 | 位置 |
| --- | --- |
| 设置 / 队列 / 最近播放 / 账号缓存 | `%APPDATA%\ClearTone` |
| 凭据（DPAPI 加密） | `%APPDATA%\ClearTone\credentials.json` |
| 音频缓存 / 封面缓存 | `%APPDATA%\ClearTone\AudioCache`、`CoverCache` |
| 辅助进程日志 | `%LOCALAPPDATA%\ClearTone\logs\helper.log` |

环境变量：

- `CLEARTONE_STORAGE_DIR` / `CLEARTONE_TEST_STORAGE_DIR`：持久化根目录（测试隔离用）；
- `CLEARTONE_HELPER_ROOT` / `CLEARTONE_HELPER_NODE`：辅助进程目录与 node 二进制覆盖
  （macOS 开发时自动定位仓库内 `HelperRuntime`，无需设置）。

## 辅助进程启动排查

优先看 `%LOCALAPPDATA%\ClearTone\logs\helper.log`。常见原因：

- 缺少 `helper\bin\node.exe` —— 运行 `scripts\fetch-node-win.ps1 -Arch <arch>`；
- 缺少 `helper\api\node_modules` —— 在 `ClearTone\Resources\HelperRuntime\api` 下执行
  `npm ci --omit=dev --ignore-scripts`；
- 杀毒软件拦截本地回环监听 —— 将安装目录加入白名单。

## 目录结构

```
windows/
  CMakeLists.txt        # cleartone_lib（OBJECT 库）+ ClearTone 可执行 + tests
  build.ps1 / build.sh  # 一键编译
  CONVENTIONS.md        # C# → C++ 移植约定（命名/异步/JSON/网络/日志）
  scripts/              # run-tests / build-app / fetch-node-win / setup-helper 调用
  src/ClearTone/
    main.cpp
    App/                # MainWindow、托盘、迷你窗、AppState（导航 + 歌单写操作）
    Core/
      Async.h           # C++20 协程 Task<T> / CancellationToken / Result / Delay
      Event.h           # 多播事件
      Models/           # 模型 + 与旧版一致的 camelCase JSON 序列化
      Networking/       # HTTPClient / HelperProcessManager / SessionExpiryGuard
      Persistence/      # StoragePaths / AppSettings / PersistenceStore(+Writer)
      Security/         # CredentialStore(DPAPI) / NeteaseCookieNormalizer
      Logging/          # CTLog（出口脱敏）
      Search|Comments|Lyrics|Discover|Artist/   # 可离线测试的状态机
    Providers/          # NeteaseProvider / NeteaseSocialProvider / LRCParser / LocalProvider
    Playback/           # PlayerController / PlayQueue / AudioEngine / AudioCacheManager
    DesignSystem/       # CTTheme / L10n / CoverImage / AmbientBackground
    Features/           # 各页面视图（纯 C++ 搭 UI，CT_REGISTER_PAGE 注册）
    Rendering/          # InFlightGate 等
  tests/                # Qt Test（tst_*.cpp，自动发现）
  runtime/              # fetch-node-win 下载的 node.exe（不入库）
```

## 架构约定（新增代码请遵守）

- 异步统一 `ct::Task<T>` 协程：`co_await` / `co_return`，取消用
  `ct::CancellationToken`，延时用 `ct::Delay(ms, ct)`；禁止阻塞事件循环。
- 事件用 `ct::Event<>` 多播（`subscribe` 返回 id，析构时 `unsubscribe`），
  不要用单一 `std::function` 回调（多视图会互相覆盖）。
- 页面用 `QWidget` + 代码布局，文件里 `CT_REGISTER_PAGE(Page::X, XView)` /
  `CT_REGISTER_OVERLAY(OverlayKind::X, View)` 注册；`cleartone_lib` 是 OBJECT 库，
  保证静态注册不被链接器丢弃。
- 有状态机的逻辑放 `Core/`（不在视图里），便于离线测试。

## 与 macOS 的差异 / 已知限制

- 音频输出默认 libVLC（无 SDK 时回退 Qt Multimedia）；
- 系统媒体控制（SMTC）只保留接入点（`App/MediaSessionIntegration.h`），未接线；
- 音频缓存不转码（macOS 用 `afconvert` 转 128kbps OPUS），直接缓存原始流；
- 菜单栏形态为系统托盘 + 独立迷你播放器窗口；
- 凭据非 Windows 平台回退到 0600 明文文件（仅开发用）。

## 界面与视觉回归

界面使用统一的深浅主题、分组导航和自适应卡片布局。`CTTheme::apply` 会同时更新
调色板、共享控件和已打开页面，保留搜索草稿等视图状态。正在播放页始终使用独立
的深色配色。卡片流布局在 `DesignSystem/FlowLayout`，不要再为资料库/搜索结果写死列数。

图标字体随资源打包，不依赖系统安装 Segoe MDL2 / Fluent Icons。
资源为 [Lucide Static 0.468.0](https://unpkg.com/lucide-static@0.468.0/font/lucide.ttf)，
许可见 `src/ClearTone/Assets/lucide-LICENSE`（同时编入应用资源）。

`tests/tst_gui_layout.cpp` 检查窄窗口播放条、卡片换行、长标题、键盘导航、主题切换、
搜索联想区和弹层边界。可在离线测试时导出实际 Qt 控件截图：

```bash
CT_GUI_SCREENSHOTS=/tmp/cleartone-gui ./scripts/run-tests.sh build-dev -R tst_gui_layout
```

模块尺寸随窗口调整：侧栏 184–224 像素，播放条在低高度窗口为 88 像素、其余为 96 像素；
歌单/专辑卡片宽度在 144–216 像素内按列均分，封面保持正方形。详情封面为 96–160
像素，操作区不足一行时自动换行。长标题和简介保留完整悬浮提示，避免把歌曲列表挤出视口。

本地 macOS Qt 预览可以验证布局，但不替代 Windows 上的字体渲染与 125% / 150%
系统缩放验收。
