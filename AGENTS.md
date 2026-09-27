# 澄音 ClearTone 开发说明

## 环境

- macOS 14.0+（**仅 macOS**，无其他平台 target）
- Xcode 15.0+（推荐 27.0）
- Swift 6.0+
- XcodeGen 2.46+（用于生成 Xcode 工程）

## 构建

```bash
# 安装 XcodeGen（如果未安装）
brew install xcodegen

# 生成 Xcode 工程
xcodegen generate

# 构建
xcodebuild -project ClearTone.xcodeproj -scheme ClearTone -configuration Debug build

# 运行测试
xcodebuild -project ClearTone.xcodeproj -scheme ClearTone -configuration Debug test
```

## 辅助进程

首次运行前需要安装 Node.js 辅助进程：

```bash
./scripts/setup-helper.sh
```

辅助进程包含：
- Node.js v22.14.0（ARM64）
- NeteaseCloudMusicApiEnhanced 4.40.1

### 辅助进程安全模型

- 仅监听 127.0.0.1
- 每次启动随机端口（21000-29000）
- 每次启动随机 UUID token，通过 X-CT-Token header 校验
- 网易云 Cookie 通过 X-CT-Cookie header 注入，不出现在 URL 中
- 主应用退出时自动跟随退出（父进程监控）
- 健康检查失败自动重启

## 目录结构

```
ClearTone/
  App/                 # 入口、窗口、菜单、AppState（导航栈 + 歌单写操作）
  Core/
    Models/            # MusicProvider(播放闭环) / MusicSocialProvider(社区/资料库)
                       # + Song/Playlist/LyricLine/Comment/TopList 等
    Networking/        # HelperProcessManager
    Persistence/       # PersistenceStore
    Search/            # SearchSession + SearchAssistStore（状态机，放这里才能被测）
    Security/          # KeychainStore + PlaintextCredentialStore
    Logging/           # CTLog（自动脱敏）
  Providers/
    Netease/           # NeteaseProvider(+MusicSocialProvider 扩展) + LRCParser
                       # + NeteaseEndpoint(路由登记表)
                       # + NeteaseDirectTransport/NeteaseCrypto/OrderedJSON
                       #   （直连+加密层，暂无生产调用方，理由见文件头注释）
    Local/             # LocalProvider
    Demo/              # DemoAudioGenerator（仅供测试夹具使用，生产代码不调用）
  Playback/            # PlayerController + PlayQueue + SongQuality + AudioCache
  Features/            # Album/Artist/Comments/Discover/Library/Login/NowPlaying
                       # /Playlist/Profile/Radio/Search/Settings/Shared/Social
  DesignSystem/        # CTColors/CTTypography/CTSpacing/L10n + CoverImage
  Rendering/           # Metal renderer + shader + SpectrumAnalyzer
  Resources/
    HelperRuntime/     # Node.js + api-enhanced（构建时打包）
    Assets.xcassets/
Tests/                 # 单元测试（XCTest）
docs/                  # 文档
scripts/               # 构建与测试脚本
```

**没有 iOS target。** 曾经的 `ClearToneiOS` 已移除 —— 它缺登录页、设置页、
歌单详情页，是一个不完整的第二交付面。恢复方法见 git history。

## 架构决策

1. **网易云接入**：本地 Node.js 辅助进程（方案 2）
   - 理由：加密协议复杂，Swift 重写成本高、风险大
   - 上游：NeteaseCloudMusicApiEnhanced（MIT）
   - `NeteaseEndpoint` 登记每条路由的真实 uri 与加密方式，
     `testEveryRequestCallSiteIsMapped` 保证「调了但没登记」不可能发生

2. **音频播放**：AVPlayer + AVPlayerItem
   - 原生支持 HTTPS 流媒体、自动缓冲、seek

3. **频谱**：Accelerate/vDSP FFT + Metal 绘制
   - MTAudioProcessingTap 对远程流媒体支持有限，当前回退到环境动画

4. **状态管理**：SwiftUI 原生 ObservableObject + @Published
   - 避免引入 TCA 等重型框架

## 注意事项

- `ClearTone/Resources/HelperRuntime/api/` **入库**（App 打包依赖的业务代码，MIT）
- `ClearTone/Resources/HelperRuntime/bin/node`（104MB）与 `api/node_modules/`（45MB）
  **不入库**：前者跑 `./scripts/setup-helper.sh` 从 nodejs.org 下载，后者 `npm ci` 复现
- 发布版本需要处理 Node.js 二进制的签名与 hardened runtime
- 当前版本使用 ad-hoc 签名，仅供开发测试

## 测试

```bash
# 运行全部测试
xcodebuild -project ClearTone.xcodeproj -scheme ClearTone -configuration Debug test

# 只跑离线单测目标（不构建 App，绕开 Metal 工具链问题）
xcodebuild -project ClearTone.xcodeproj -target ClearToneTests -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO
xattr -cr build/Debug/ClearToneTests.xctest && codesign --force --sign - build/Debug/ClearToneTests.xctest
xcrun xctest -XCTest PlayQueueTests build/Debug/ClearToneTests.xctest

# 注意：测试 bundle 若位于带扩展属性的目录（iCloud/File Provider 同步的桌面等），
# 签名阶段会报 "resource fork, Finder information, or similar detritus not allowed"，
# 用上面的 xattr -cr 清掉再 ad-hoc 签一次即可。
```

当前覆盖（**33 个测试文件 / 327 项**，全部离线可跑且全绿）：

| 关注点 | 测试 |
|---|---|
| 播放队列 | PlayQueueTests / ShuffleHistoryTests / DoubleClickPlaybackTests |
| 播放器异步状态 | PlayerControllerTests（停止作废在途请求、切歌停表、加载期暂停/续播、切音质保进度）、SeekTokenTests、PlaybackStateSemanticsTests |
| 搜索状态机 | SearchSessionTests（分页不读草稿、清空作废在途请求、旧响应丢弃）/ SearchSessionPaginationTests（**四种类型都能翻页**、分页锁）/ SearchAssistStoreTests（联想节流、历史） |
| 歌词 / 电台 / 每日推荐 | LRCParserTests / RadioParsingTests / RadioContractTests / DailyRecommendTests |
| 社区与资料库 | NeteaseSocialParsingTests（评论/通知/私信/榜单/等级/热搜的**字段名**逐个对着上游 `home.md` 核） |
| 接口契约 | NeteaseEndpointTests（含 `testEveryRequestCallSiteIsMapped` 扫描调用点）/ NeteaseEapiTests（eapi 与 Node 逐字节对照） |
| 加解密 | NeteaseCryptoTests / NeteaseEapiTests |
| 封面 | CoverImageTests / CoverImageRetryTests / CoverImageThreadSafetyTests |
| 缓存 / 频谱 | AudioCacheManagerPolicyTests / ResponseCacheLimitsTests / SpectrumProcessorTests |
| 菜单命令 | PlaybackCommandTests（播放模式轮转、相对 seek 不越界） |
| 其它 | LikedStateTests / DemoAudioGeneratorTests / SongQualityPolicyTests / PlayingSourceInfoTests |

全部用桩 Provider / 录制器，不联网、不写真实用户状态（`PlayerControllerTests` 会把持久化
重定向到临时目录，`SearchAssistStoreTests` 注入独立 UserDefaults suite）。
**真正联网的接口验证只能靠实机跑 App** —— 离线测试能证明「我们读的键名与接口约定一致」，
不能证明「接口真的返回了这些字段」。

### eapi 向量的产生方式

`Tests/NeteaseEapiTests.swift` 里的期望密文由**仓库内打包的 Node 运行时**生成：

```bash
./ClearTone/Resources/HelperRuntime/bin/node your-script.js
# require api/util/crypto.js 的 eapi(uri, payload).params
```

重新启用直连路径或改动 eapi 相关代码后，应重跑对照，而不是手改期望值。

