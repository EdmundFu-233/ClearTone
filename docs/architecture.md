# 澄音 ClearTone 架构文档

## 概述

澄音（ClearTone）是一款 macOS 原生第三方网易云音乐播放器，使用 SwiftUI + AVFoundation + Metal 构建。本文档描述核心技术方案与决策理由。

## 1. 网易云接入方案

### 决策：本地 API 辅助进程

**选择**：方案 2/3 — 本机 API 辅助进程（Node.js + NeteaseCloudMusicApiEnhanced）。

**理由**：
- 网易云官方未开放公共 API，所有第三方接入都依赖逆向的 weapi/eapi 加密协议。
- 加密算法（AES + RSA + 随机参数）在 Swift 中重写成本高、风险大，且上游会持续变化。
- NeteaseCloudMusicApiEnhanced（MIT 许可证）维护活跃，接口全面（2000+ commits，2026 年仍活跃）。
- 提示词明确允许在原生协议重实现影响稳定性时使用本机辅助进程。

### 架构

```
┌─────────────────────────────────────┐
│  ClearTone.app (SwiftUI/AppKit)     │
│  ┌─────────────────────────────┐    │
│  │  HelperProcessManager       │    │
│  │  - 启动/停止/健康检查        │    │
│  │  - 随机端口 + 每次启动 token │    │
│  └──────────┬──────────────────┘    │
└─────────────┼───────────────────────┘
              │ HTTP 127.0.0.1:PORT
              │ Header: X-CT-Token
┌─────────────▼───────────────────────┐
│  HelperRuntime (打包在 .app 内)      │
│  ├── bin/node (v22.14.0)           │
│  └── api/ (NeteaseCloudMusicApi)   │
│      └── 仅监听 127.0.0.1          │
└─────────────────────────────────────┘
```

### 安全措施
- **回环监听**：仅绑定 127.0.0.1，不开放到局域网。
- **随机端口**：每次启动使用 21000-29000 之间随机端口。
- **访问令牌**：每次启动生成 UUID token，通过 `X-CT-Token` header 校验。
- **凭证传递**：网易云 Cookie 通过 `X-CT-Cookie` header 注入，不出现在 URL/进程参数/日志中。
- **日志脱敏**：`CTLog.sanitize` 自动过滤 cookie/token/key 等敏感字段。
- **生命周期**：主应用退出时自动停止辅助进程；健康检查失败自动重启。
- **健康检查**：`/ct_health` 端点验证 token 并返回状态。

### 已知限制
- 首次启动辅助进程需要联网注册匿名 token（`register_anonimous`），约需 5-10 秒。
- `xeapi public key is missing` 警告：api-enhanced 4.40.1 已知问题，不影响核心功能。
- 辅助进程依赖网络访问网易云服务器，断网时不可用。

## 2. 音频播放方案

### 决策：AVPlayer + AVPlayerItem

**理由**：
- AVPlayer 原生支持 HTTPS 流媒体、自动缓冲、seek、HTTP  Range 请求。
- 与系统媒体控制（MediaPlayer framework）集成成熟。
- 不需要手动管理解码/缓冲/时钟同步。

### 频谱方案
- **MTAudioProcessingTap 验证结果**：对 HTTPS 远程流媒体支持有限，AVFoundation 不允许对远程流安装 tap（需要本地文件或特殊格式）。
- **当前实现**：`SpectrumAnalyzer` 使用 Accelerate/vDSP FFT，但 `attach(to: AVPlayerItem)` 明确标记为不可用并抛出异常。
- **回退**：设置中提供「真实频谱 / 环境动画 / 关闭」三选项，当前版本默认使用「环境动画」（程序生成的平滑动画，明确标注非真实频谱）。
- **后续计划**：本地文件可通过 AVAudioEngine + installTap 实现真实频谱；远程流媒体需要预下载或自定义缓冲方案。

## 3. 状态模型

### 播放状态机
```swift
enum PlaybackState {
    case idle
    case loading(songID: String)
    case playing(songID: String)
    case paused(songID: String)
    case buffering(songID: String)
    case ended(songID: String)
    case failed(songID: String, reason: String)
}
```

- **用户意图与系统状态分离**：`isUserSeeking` 标志防止 seek 过程中状态被自动更新覆盖。
- **generation token**：每次切歌递增 generation，迟到的加载完成响应被丢弃。
- **连续失败上限**：3 次失败后停止自动切换，避免无限刷请求。

### 队列模型
- 每个 `QueueItem` 有独立 UUID，支持同一首歌重复加入。
- 随机模式维护 `shuffleHistory` 栈，「上一首」返回实际听过的曲目。
- 队列持久化到 `~/Library/Application Support/ClearTone/queue.json`。

## 4. Metal 渲染

### 动态背景
- `AmbientBackgroundRenderer` 封装 `MTKView`，通过 `NSViewRepresentable` 接入 SwiftUI。
- shader：`Shaders.metal` 中的 `fragment_ambient` 实现低对比流动渐变（基于封面提取的 3-5 个颜色）。
- 封面颜色提取：只在封面变化时执行一次并缓存。
- 性能模式：
  - 自动：根据窗口可见性/低电量模式调整
  - 节能：renderScale 0.3，约 30 fps
  - 高质量：renderScale 0.6，目标 60 fps
  - 静态：停止 Metal 绘制，显示静态渐变

### 频谱绘制
- 频谱数据通过 `fragment bytes` 传入 shader，64 个对数频带。
- FFT 使用 Accelerate/vDSP（不强行移到 Metal）。

## 5. 持久化

| 数据 | 存储 | 说明 |
|------|------|------|
| Cookie/Token | Keychain | `KeychainStore`，kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly |
| 播放队列 | Application Support | JSON 文件 |
| 用户设置 | UserDefaults | 通过 `PersistenceStore` 包装 |

## 6. 目录结构

```
ClearTone/
  App/                 # 入口、窗口、菜单、AppState（导航栈 + 歌单写操作）
  Core/
    Models/            # MusicProvider(播放闭环) + MusicSocialProvider(社区/资料库)
    Networking/        # HelperProcessManager
    Persistence/       # PersistenceStore
    Search/            # SearchSession + SearchAssistStore（状态机，放这里才能被测）
    Security/          # KeychainStore + PlaintextCredentialStore
    Logging/           # CTLog
  Providers/
    Netease/           # NeteaseProvider(+SocialProvider 扩展) + LRCParser
                       # + NeteaseEndpoint(路由登记表) + 直连/加密层(暂无生产调用方)
    Local/             # LocalProvider
    Demo/              # DemoAudioGenerator（仅供测试夹具使用）
  Playback/            # PlayerController + PlayQueue + SongQuality + AudioCache
  Features/
    Album/ Artist/ Comments/ Discover/ Library/ Login/ NowPlaying/
    Playlist/ Profile/ Radio/ Search/ Settings/ Shared/ Social/
  DesignSystem/        # CTColors/CTTypography/CTSpacing/L10n + CoverImage
  Rendering/           # Metal renderer + shader + SpectrumAnalyzer
  Resources/
    HelperRuntime/     # Node.js + api-enhanced
    Assets.xcassets/
Tests/                 # 单元测试（33 个文件 / 327 项，全部离线）
docs/                  # 文档
scripts/               # 构建与测试脚本
```

## 6.1 两个 Provider 协议

| 协议 | 覆盖 | 实现者 |
|---|---|---|
| `MusicProvider` | 播放闭环：登录、搜索、播放地址、歌词、队列 | Netease / Local |
| `MusicSocialProvider` | 社区与资料库：歌单写操作、收藏、榜单、评论、消息、等级 | 仅 Netease |

拆成两个是因为后者**只有在线账号才有**。塞进 `MusicProvider` 会迫使
`LocalProvider` 写几十个 `throw .notLoggedIn`，噪音大且无信息量。

## 6.2 已无生产调用方的代码

`Providers/Netease/` 下的 `NeteaseDirectTransport` / `NeteaseCrypto` /
`OrderedJSON` 是一套**不经辅助进程直连网易云**的完整实现（weapi 双重 AES +
raw RSA、eapi MD5 + AES-ECB），加密链路已与 Node 标准答案逐字节对齐
（`Tests/NeteaseEapiTests.swift`，18 项）。

`ClearToneiOS` target 移除后它没有调用方，但保留：
1. 它是唯一不依赖 Node 的实现 —— 去掉 169MB Node 依赖时这就是路基；
2. `NeteaseEndpoint` 同时是**路由登记表**，
   `NeteaseEndpointTests.testEveryRequestCallSiteIsMapped` 扫描所有
   `request("...")` 调用点，保证不存在「调了但没登记」的路由
   （`/song/detail` 当初就是这么漏的）。

## 7. 决策记录

| 决策 | 选择 | 理由 |
|------|------|------|
| UI 框架 | SwiftUI + AppKit | 现代声明式 UI，必要处用 AppKit 补足桌面行为 |
| 网络层 | 辅助进程 | 加密协议复杂，MIT 许可上游稳定 |
| 音频播放 | AVPlayer | 原生流媒体支持，系统集成成熟 |
| 状态管理 | ObservableObject + @Published | SwiftUI 原生，避免引入 TCA 等重型框架 |
| 并发 | async/await + actor | Swift 6 严格并发，MainActor 隔离 UI |
| 持久化 | JSON + UserDefaults + Keychain | 简单可靠，无需 SwiftData 迁移成本 |
| Metal 用途 | 背景 + 频谱绘制 | 不强行把 FFT 移到 GPU |
