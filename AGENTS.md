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
# 推荐：跑全部离线单测（脚本会做持久化隔离，必须用它而不是裸 xctest）
./scripts/run-tests.sh

# 运行全部测试（含 App target，会编 Metal 资源）
xcodebuild -project ClearTone.xcodeproj -scheme ClearTone -configuration Debug test
```

### ⚠️ 离线单测必须**先编 App target**

```bash
# 顺序不能反。第一步产出 build/Debug/ClearTone.swiftmodule，
# 第二步的测试目标靠 -I build/Debug 才能 import 到它。
xcodebuild -project ClearTone.xcodeproj -target ClearTone -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO
xcodebuild -project ClearTone.xcodeproj -target ClearToneTests -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO
```

原因：App 的 `PRODUCT_NAME` 是中文「澄音」，Swift 会跟着把**模块名**也定成
「澄音」，于是 Debug 下产出的是 `build/Debug/澄音.swiftmodule` ——
**没有** `ClearTone.swiftmodule`，而所有测试文件都写着 `@testable import ClearTone`。
所以 App 目标上钉了 `PRODUCT_MODULE_NAME: ClearTone`（见 `project.yml`）。

在这之前它靠显式模块构建里「从同一 target 源文件隐式拼出 ClearTone 模块」那条
兜底路径编过，而那条路径**只要 `Tests/` 下新增任何一个文件就会失效**，报的是
`Unable to resolve module dependency: 'ClearTone'` —— 一个完全不提真正原因的
错误（基线代码 + 一个 6 行的空测试文件即可必现）。

两个**不要**：
- 不要在 `ClearToneTests` 上加 `dependencies: [target: ClearTone]`。
  测试目标自己就编译了 `ClearTone/**` 的源文件，多一次链接会去找
  `ClearTone.app`（target 名），而产物叫 `澄音.app`，ld 直接失败。
- 不要绕过 `scripts/run-tests.sh` 裸跑 `xctest`：脚本用
  `CLEARTONE_TEST_STORAGE_DIR` 把持久化重定向到临时目录，裸跑会写到真实用户目录
  （`SongQualityPolicyTests` 有断言专门拦这个）。

测试 bundle 若位于带扩展属性的目录（iCloud/File Provider 同步的桌面等），
签名阶段会报 "resource fork, Finder information, or similar detritus not allowed"，
用 `xattr -cr` 清掉再 ad-hoc 签一次即可（`run-tests.sh` 已经做了）。

当前覆盖（**41 个测试文件 / 411 项**，全部离线可跑且全绿）：

| 关注点 | 测试 |
|---|---|
| 播放队列 | PlayQueueTests / ShuffleHistoryTests / DoubleClickPlaybackTests |
| 播放器异步状态 | PlayerControllerTests（停止作废在途请求、切歌停表、加载期暂停/续播、切音质保进度）、SeekTokenTests、PlaybackStateSemanticsTests |
| 搜索状态机 | SearchSessionTests（分页不读草稿、清空作废在途请求、旧响应丢弃）/ SearchSessionPaginationTests（**四种类型都能翻页**、分页锁）/ SearchAssistStoreTests（联想节流、历史） |
| **会话失效判定** | **SessionExpiryGuardTests**（单次 301/403 不定罪、需 `/user/account` 旁证、探针在途不递归、复位） |
| **歌手资料页** | **ArtistProfileSessionTests**（换歌手清空、offset 由已加载条数推导、翻页失败保留旧数据、迟到响应丢弃、followed 不被后续页抹掉）/ **ArtistProfileParsingTests**（`cover`/`avatar` 才是头像、MV 的 `artistName`/`imgurl16v9`、eapi 键序与重命名） |
| 歌词 / 电台 / 每日推荐 | LRCParserTests / RadioParsingTests / RadioContractTests / DailyRecommendTests |
| 社区与资料库 | NeteaseSocialParsingTests（评论/通知/私信/榜单/等级/热搜的**字段名**逐个对着上游 `home.md` 核） |
| 接口契约 | NeteaseEndpointTests（含 `testEveryRequestCallSiteIsMapped` 扫描调用点）/ NeteaseEapiTests（eapi 与 Node 逐字节对照，含 module 写死参数的 `constants` 登记） |
| 加解密 | NeteaseCryptoTests / NeteaseEapiTests |
| 封面 | CoverImageTests / CoverImageRetryTests / CoverImageThreadSafetyTests |
| 缓存 / 频谱 | **AudioCacheManagerPolicyTests**（容量 LRU、代次防复活、临时文件、正在播放保护、**128kbps 目标码率**、**7 天保留期限**：`cachedAt` 而非 `lastAccessedAt` 计时、时钟回拨不误清）/ ResponseCacheLimitsTests / SpectrumProcessorTests |
| 菜单命令 | PlaybackCommandTests（播放模式轮转、相对 seek 不越界）/ **SidebarShortcutsTests**（⌘1…⌘0 映射；**第 10 项不得 `Character("10")`**、越界返回 nil） |
| 凭据与限流 | **NeteaseCookieNormalizerTests**（Set-Cookie 拼接串归一化：**134 段 → 5 段**、丢属性/空值/重名、值含 `=`、**幂等**、**`loadLoginCookie` 不得自我递归**）/ **LikeWriteThrottleTests**（405/524 算限流需冷却、其余错误不冷却、提示要劝阻连点） |
| 音质默认值 | SongQualityPolicyTests（**VIP→无损 / 非 VIP→极高**、「自动」哨兵值、**显式选择不因 VIP 变化而改动**）/ PlaybackFeaturesTests（缺键=自动、**老用户存下的显式值不被新默认覆盖**） |
| 其它 | LikedStateTests / DemoAudioGeneratorTests / PlayingSourceInfoTests |

全部用桩 Provider / 录制器，不联网、不写真实用户状态（`PlayerControllerTests` 会把持久化
重定向到临时目录，`SearchAssistStoreTests` 注入独立 UserDefaults suite）。
**真正联网的接口验证只能靠实机跑 App** —— 离线测试能证明「我们读的键名与接口约定一致」，
不能证明「接口真的返回了这些字段」。

> **可测性约定**：`project.yml` 把 `Features/**` 排除在测试 target 之外，
> 所以放在那里的 store 一个都测不到（`LibraryStore` / `CommentsStore` /
> `SocialStore` 都是这么废掉的）。**有状态机的东西放 `Core/`** ——
> 照 `Core/Search/SearchSession.swift` 与 `Core/Artist/ArtistProfileSession.swift`
> 的样子，纯逻辑在 `Core/`，SwiftUI 壳留在 `Features/`。

### eapi 向量的产生方式

`Tests/NeteaseEapiTests.swift` 里的期望密文由**仓库内打包的 Node 运行时**生成：

```bash
./ClearTone/Resources/HelperRuntime/bin/node your-script.js
# require api/util/crypto.js 的 eapi(uri, payload).params
```

重新启用直连路径或改动 eapi 相关代码后，应重跑对照，而不是手改期望值。

