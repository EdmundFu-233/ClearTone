# 澄音 ClearTone

一款使用 **SwiftUI、AVFoundation 和 Metal** 构建的 macOS 原生第三方网易云音乐播放器。将在线音乐、本地曲库、同步歌词和桌面播放控制放在同一个应用里。

目前处于开发阶段，仅提供 macOS target。当前辅助进程安装脚本面向 **Apple Silicon**，不提供开箱即用的 Intel Mac、iOS、Windows 或 Linux 构建流程。

## 功能

- **发现与搜索**：歌曲、专辑、歌手、歌单搜索，搜索联想与历史、榜单、每日推荐、私人 FM 和电台。
- **在线资料库**：二维码登录、喜欢的音乐、歌单管理、专辑与歌手详情、个人资料、评论和消息页面。
- **本地音乐**：导入文件或文件夹，读取元数据并保存曲库索引。支持导入 MP3、M4A、AAC、WAV、FLAC、AIFF、ALAC，实际解码能力取决于系统。
- **播放控制**：播放队列、随机播放历史、音质选择、系统媒体控制、菜单栏播放器和迷你播放器。
- **歌词与外观**：LRC / YRC 歌词解析、翻译与音译、歌词偏移调节、深浅色主题和 Metal 动态背景。
- **音频缓存**：将在线歌曲转为目标 96 kbps 的 OPUS 缓存，再次播放优先使用缓存；可为单曲指定在线音质以跳过缓存。

以上为已实现的功能入口，不代表所有联网接口均已完成实机验证。账号权限、内容可用性及上游接口变化会影响在线功能。

## 开发环境

| 项目 | 要求 |
| --- | --- |
| 系统与硬件 | macOS 14.0+，Apple Silicon Mac |
| Xcode | 配备 Swift 6 工具链及可用 Metal 编译工具的完整 Xcode |
| Swift | 6.0+ |
| XcodeGen | 2.46+ |
| Node.js / npm | 开发机需有可用的 `npm`，用于安装辅助进程依赖 |
| 签名 | 本机 Apple Development 证书及对应开发团队 |

应用运行使用随包携带的 Node.js v22.14.0（ARM64），无需用户另行安装 Node.js。构建准备阶段仍需要开发机上的 `npm`：安装脚本只复制运行时的 `node` 二进制，不携带 npm。

## 从源码运行

以下命令均在仓库根目录执行。

### 1. 准备依赖

如果开发机尚未安装 XcodeGen 或 Node.js / npm，可使用 Homebrew 安装：

```bash
brew install xcodegen node
```

安装并首次打开完整 Xcode，完成其组件安装。检查当前命令行工具链：

```bash
xcodebuild -version
xcrun swift --version
xcodegen --version
npm --version
```

### 2. 安装辅助进程

```bash
./scripts/setup-helper.sh
```

脚本下载 Node.js v22.14.0，并在缺少 `node_modules` 时运行 `npm ci --omit=dev --ignore-scripts`。

- `ClearTone/Resources/HelperRuntime/api/` 已入库，包含基于 NeteaseCloudMusicApiEnhanced 4.40.1 的辅助进程代码。
- `bin/node` 与 `api/node_modules/` 不入库，首次构建前必须准备好。
- 安装过程需要访问 Node.js 下载站和 npm registry；正常克隆无需重新下载 API 源码。

### 3. 配置开发签名

将 [project.yml](project.yml) 中两个 target 的 `DEVELOPMENT_TEAM` 改为自己的团队 ID，并确保钥匙串中存在该团队的 Apple Development 证书。

工程由 XcodeGen 生成；需要持久保留的构建配置应修改 `project.yml`。

### 4. 构建并打开应用

推荐使用仓库脚本完成编译、嵌套 Node 签名、应用签名和辅助进程启动自检：

```bash
# 生成工程并构建 Release；暂不安装到 /Applications
./scripts/build-app.sh --no-install

# 打开构建产物
open /tmp/cleartone-stage/澄音.app
```

去掉 `--no-install` 会安装到 `/Applications/澄音.app`，并替换该位置已有的同名应用。

日常开发也可打开生成的 Xcode 工程，选择 `ClearTone` scheme：

```bash
xcodegen generate
open ClearTone.xcodeproj
```

或在终端执行 Debug 构建：

```bash
xcodebuild -project ClearTone.xcodeproj -scheme ClearTone \
  -configuration Debug -derivedDataPath ./DerivedData build
```

当前构建脚本使用 **Apple Development 证书 + hardened runtime，未公证**。向其他用户分发前仍需处理 Developer ID 签名和公证；本地构建成功不等于可公开分发。

## 开始使用

1. 启动后等待本地辅助进程就绪，通过头像入口打开登录页，使用网易云音乐手机 App 扫码并确认。
2. 从搜索、发现或个人资料库选择音乐，使用播放栏和队列控制播放。
3. 在「本地音乐」导入文件或文件夹。本地曲库保存原文件路径，移动或删除原文件会影响后续播放。
4. 在设置中调整外观、播放音质、缓存、歌词与窗口行为。

缓存采用有损 OPUS 编码，不能保留无损或 Hi-Res 音源品质。希望为某首歌使用在线音质时，可点击播放栏或正在播放页的音源标签进行选择；实际可用音质受账号和歌曲权限限制。

## 本地数据与辅助进程

主应用通过本机 Node.js 辅助进程访问网易云服务：

```text
SwiftUI / AppKit
      │
NeteaseProvider → HelperProcessManager
      │ HTTP · 127.0.0.1 · 随机端口 · X-CT-Token
      ▼
Node.js + NeteaseCloudMusicApiEnhanced → 网易云服务
```

- 辅助进程仅监听 `127.0.0.1`，每次启动从 `21000–29000` 选择随机端口，并使用随机 UUID token 验证请求。
- 网易云 Cookie 通过 `X-CT-Cookie` 请求头传递；主应用负责进程生命周期和健康检查，异常时尝试重启。
- 当前应用未启用 App Sandbox。
- **登录凭据默认以明文保存在本机**：`~/Library/Application Support/ClearTone/credentials.json`。实现会尝试将文件权限设为 `0600`；文件权限不等于加密。可在「设置 → 登录凭据」选择系统钥匙串。
- 队列及本地曲库等数据保存在 `~/Library/Application Support/ClearTone/`，辅助进程日志位于 `~/Library/Logs/ClearTone/helper.log`。

提交问题或日志时，请移除 Cookie、token 和其他账号凭据，不要上传 `credentials.json`。

## 测试

推荐使用离线测试脚本；它仅构建测试 target，绕开 App 的 Metal 构建，并为持久化数据设置临时目录：

```bash
xcodegen generate

# 重新构建并运行全部离线单元测试
./scripts/run-tests.sh

# 只运行指定测试类
./scripts/run-tests.sh PlayQueueTests
```

只有确认测试产物与当前源码一致时，才使用 `./scripts/run-tests.sh --no-build` 复用已有 bundle。

也可运行完整 scheme 的测试流程，该流程会同时涉及 App 构建与签名：

```bash
xcodebuild -project ClearTone.xcodeproj -scheme ClearTone \
  -configuration Debug test
```

测试覆盖播放队列与异步状态、搜索与分页、歌词解析、接口路由与加密契约、封面与缓存等逻辑。离线桩与加密向量能够验证本地实现，但不能证明真实账号登录、在线播放或上游接口当前可用；这些需要实机验证。测试脚本输出的跳过项也不能视为已通过。

## 常见问题

### 辅助进程启动失败或提示 MODULE_NOT_FOUND

先运行 `./scripts/setup-helper.sh`，确认 `HelperRuntime/bin/node`、`HelperRuntime/api/app.js` 和 `HelperRuntime/api/node_modules/` 均存在。再查看「设置 → 高级 → 诊断信息」和辅助进程日志。

若签名后 Node 无输出便退出，使用 `build-app.sh` 重新构建，检查脚本的辅助进程自检结果；Node 的 V8 运行需要相应 JIT entitlement。

### 找不到开发证书

确认 `project.yml` 的团队 ID 与本机证书一致。构建脚本会按团队选择 Apple Development 证书，不会自动使用其他团队的身份。

### 签名提示 resource fork 或 Finder information

桌面等同步目录可能为构建产物附加扩展属性。`build-app.sh` 会将产物复制到 `/tmp/cleartone-stage` 后清理属性并签名；离线测试脚本也包含测试 bundle 的属性清理与 ad-hoc 签名步骤。

### Metal 工具链导致构建失败

检查是否选中了完整 Xcode，以及所需 Metal 组件是否安装。只验证业务逻辑时，可先运行 `./scripts/run-tests.sh`；这不代表 App 已成功构建。

### 无法播放，或音质与设置不同

检查网络、登录状态和歌曲权限。默认播放可能命中 OPUS 缓存；需要在线音质时，为单曲指定音质并跳过缓存。

### 频谱没有随歌曲变化

当前版本的音频采样接入受限，使用环境动画回退。动态视觉效果不能视为真实音频频谱。

## 项目结构

```text
ClearTone/
  App/                 # 应用入口、窗口、菜单、共享状态
  Core/                # 模型、网络、持久化、安全、搜索状态机、日志
  Providers/           # 网易云与本地音乐接入；Demo 仅供测试夹具
  Playback/            # 播放控制、队列、音质与音频缓存
  Features/            # 搜索、发现、资料库、歌词、社区与设置等页面
  DesignSystem/        # 颜色、排版、间距、本地化与封面组件
  Rendering/           # Metal 背景、shader 与频谱处理
  Resources/           # 应用资源及打包的辅助进程
Tests/                 # XCTest 单元测试
scripts/               # 环境准备、构建与测试脚本
docs/                  # 架构、接口能力、验证记录与设计资料
project.yml            # XcodeGen 工程配置
```

生产网络请求使用本地辅助进程。仓库保留的 `NeteaseDirectTransport`、`NeteaseCrypto` 和 `OrderedJSON` 直连加密实现目前没有生产调用方。

## 更多文档

- [开发约定](AGENTS.md)
- [架构说明](docs/architecture.md)
- [API 能力说明](docs/api-capabilities.md)
- [验证记录与手工检查项](docs/verification.md)
- [性能说明](docs/performance.md)
- [UI / UX 记录](docs/ui-ux/README.md)

部分文档是阶段性记录；构建与运行行为以当前源码、脚本和实际验证结果为准。

## 项目声明与第三方组件

澄音是独立的第三方客户端，与网易云音乐官方无关联。不提供 VIP 解锁、DRM 绕过或地区限制绕过功能；音乐内容及相关权利归各自权利人所有。

第三方组件及许可证说明见 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES)。仓库当前未提供项目自身的独立 `LICENSE` 文件，第三方组件的 MIT 许可不代表本项目整体采用 MIT 许可。
