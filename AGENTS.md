# 澄音 ClearTone 开发说明

## 环境

- macOS 14.0+；iOS / iPadOS 17.0+（`ClearToneiOS` target）
- Xcode 15.0+（推荐 27.0）
- Swift 6.0+
- XcodeGen 2.46+（用于生成 Xcode 工程）

## 构建

```bash
# 安装 XcodeGen（如果未安装）
brew install xcodegen

# 生成 Xcode 工程
xcodegen generate

# 构建（⚠️ 不要用 `-scheme ClearTone build` 一把梭，理由见下）
xcodebuild -project ClearTone.xcodeproj -target ClearTone -configuration Debug build CODE_SIGNING_ALLOWED=NO

# 运行测试
./scripts/run-tests.sh
```

> **`-scheme ClearTone build` / `test` 目前是坏的**，而且与本次改动无关
> （在干净的 HEAD 上同样失败）：`ClearToneTests` **不能**加
> `dependencies: [target: ClearTone]`（加了会变成 host app + 嵌入 + 链
> `ClearTone.app`，而产物叫 `澄音.app`），于是两个 target 之间**没有任何
> 顺序关系**，scheme 的 `parallelizeBuildables=YES` 让测试目标在 App 产出
> `ClearTone.swiftmodule` 之前就开跑，报
> `Unable to resolve module dependency: 'ClearTone'`。
> 这个错误**一个字都不提真正的原因**。所以一律走
> 「先 `-target ClearTone`、再 `-target ClearToneTests`」的两步，
> `scripts/run-tests.sh` 已经把顺序钉死了。

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
                       #   （iOS 原生直连+加密层，含 xeapi）
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

iOS target 已补齐登录、设置与详情页。构建与免费账号签名见
`docs/ios/README.md`；iOS 不打包 Node，不需要执行 setup-helper。

```bash
./scripts/build-ios.sh --simulator
./scripts/build-ios.sh --ipa
```

**iOS 不得增加需要付费开发者账号的 entitlement / capability。**
当前无 iOS 自定义 entitlement / SystemCapabilities，团队 ID 留空供用户选 Personal Team。
后台音频仅使用 Info.plist 的 `UIBackgroundModes: [audio]` 与 AVAudioSession；
默认钥匙串不启用 Keychain Sharing。

## 架构决策

1. **网易云接入**：macOS 本地 Node.js 辅助进程；iOS 原生直连
   - 理由：加密协议复杂，Swift 重写成本高、风险大
   - 上游：NeteaseCloudMusicApiEnhanced（MIT）
   - iOS 的参数翻译在 NeteaseMobileRoute；xeapi 的 AES/X25519/GCM 对照仓库 Node 向量验证
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
# 跑全部离线单测（脚本会做持久化隔离，必须用它而不是裸 xctest）
./scripts/run-tests.sh
```

> **没有别的入口。** `-scheme ClearTone test` 与 `-scheme ClearTone build`
> 一样是坏的（两个 target 之间没有依赖关系，测试目标抢跑在 App 产出
> `ClearTone.swiftmodule` 之前），报错文案完全不提这个原因。见上文「构建」。

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

当前覆盖（**51 个测试文件 / 513 项**，全部离线可跑且全绿）：

| 关注点 | 测试 |
|---|---|
| 播放队列 | PlayQueueTests / ShuffleHistoryTests / DoubleClickPlaybackTests |
| 播放器异步状态 | PlayerControllerTests（停止作废在途请求、切歌停表、加载期暂停/续播、切音质保进度、**`resume()` 在 `.failed` 下必须重建播放源**：线控/控制中心直连 `resume()`，原先会把状态写成 `.playing` 却一声不响）、SeekTokenTests、PlaybackStateSemanticsTests |
| 搜索状态机 | SearchSessionTests（分页不读草稿、清空作废在途请求、旧响应丢弃）/ SearchSessionPaginationTests（**四种类型都能翻页**、分页锁、**取消在途页码回滚**、**分页失败保留旧数据但置 `paginationError`**、**失败的查询不得留下旧 `result`**）/ SearchAssistStoreTests（联想节流、历史、**热搜请求被取消后 loading 必须复位**、历史读入即裁剪到 20、`removeHistory` 大小写不敏感） |
| **会话失效判定** | **SessionExpiryGuardTests**（单次 301/403 不定罪、需 `/user/account` 旁证、探针在途不递归、复位） |
| **歌手资料页** | **ArtistProfileSessionTests**（换歌手清空、offset 由已加载条数推导、翻页失败保留旧数据、迟到响应丢弃、followed 不被后续页抹掉）/ **ArtistProfileParsingTests**（`cover`/`avatar` 才是头像、MV 的 `artistName`/`imgurl16v9`、eapi 键序与重命名） |
| 歌词 / 电台 / 每日推荐 | LRCParserTests / RadioParsingTests / RadioContractTests / DailyRecommendTests |
| 榜单 | **TopListSessionTests**（榜单目录：失败**保留旧数据**但置错误、**迟到的旧响应不得覆盖新响应**、取消后 `isLoading` 必须复位）。macOS 的 `TopListStore` 在 `Features/` 里，一条断言都写不了 —— 这份逻辑就是为可测性抽到 `Core/Discover/` 的 |
| 社区与资料库 | NeteaseSocialParsingTests（评论/通知/私信/榜单/等级/热搜的**字段名**逐个对着上游 `home.md` 核） |
| 接口契约 | NeteaseEndpointTests（含 `testEveryRequestCallSiteIsMapped` 扫描调用点、**`testEveryKnownRouteHasAnUpstreamModuleFile`** 反查 `api/module/*.js` 是否存在、`testIOSReachableRoutesAreAdaptedByMobileRoute` 钉死 iOS 适配清单）/ NeteaseEapiTests（eapi 与 Node 逐字节对照，含 module 写死参数的 `constants` 登记、query 值恒为字符串） / `scripts/probes/endpoint-table.js`（拿打包 Node 打桩 module，逐条比对 uri / crypto / 上游是否存在）/ `scripts/probes/log-redaction.js`（**日志出口脱敏**：cookie/`MUSIC_U`/`NMTID` 不得出现在 logger 与 `request.js` 的 `[ERR]` 输出里） |
| 加解密 | NeteaseCryptoTests / NeteaseEapiTests |
| 封面 | CoverImageTests / CoverImageRetryTests / CoverImageThreadSafetyTests |
| 缓存 / 频谱 | **AudioCacheManagerPolicyTests**（容量 LRU、代次防复活、临时文件、正在播放保护、**128kbps 目标码率**、**7 天保留期限**：`cachedAt` 而非 `lastAccessedAt` 计时、时钟回拨不误清、**`isCacheFile` 跟随平台扩展名**：写死 `.caf` 会让 iOS 每次启动清空整个索引且 LRU 失效）/ ResponseCacheLimitsTests / SpectrumProcessorTests |
| **渲染背压** | **InFlightGateTests**（占位/归还严格配对、**并发计数恰好停在上限**、`release` 不下穿 0）。`AmbientBackgroundRenderer` 需要 MTLDevice + `Bundle.main` shader 且被 `project.yml` 排除，判定逻辑必须抽成 `Rendering/InFlightGate.swift` 才测得到 |
| **持久化** | **PersistenceWriterTests**（只排队列也落盘、只排 recent 也落盘、**NaN 快照样写出**、**单个 NaN 字段不连累整份 `AppSettings`**、写出失败回补 pending 并限次自动重试） |
| 菜单命令 | PlaybackCommandTests（播放模式轮转、相对 seek 不越界）/ **SidebarShortcutsTests**（⌘1…⌘0 映射；**第 10 项不得 `Character("10")`**、越界返回 nil） |
| 凭据与限流 | **NeteaseCookieNormalizerTests**（Set-Cookie 拼接串归一化：**134 段 → 5 段**、丢属性/空值/重名、值含 `=`、**幂等**、**`loadLoginCookie` 不得自我递归**）/ **LikeWriteThrottleTests**（405/524 算限流需冷却、其余错误不冷却、提示要劝阻连点）/ **KeychainStoreTests**（`delete` 必须**双后端都清**、**主动后端失败不继续删另一侧**、**双向迁移：先写目标成功才删源**、凭据文件落在 `storageRoot` 且 **0600**、`storageMode` 缺省 iOS=keychain / macOS=plaintextFile） |
| 音质默认值 | SongQualityPolicyTests（**VIP→无损 / 非 VIP→极高**、「自动」哨兵值、**显式选择不因 VIP 变化而改动**）/ PlaybackFeaturesTests（缺键=自动、**老用户存下的显式值不被新默认覆盖**） |
| iOS 直连与移动状态 | NeteaseMobileRouteTests（QR 的 uri/crypto 走登记表、`/search/suggest` 的 `s` 键、`/logout` 恒 eapi 空 body、**`/search/hot` 写死 `type=1111`**、**`/toplist` 空 body**、plain 表单标量拼写）/ NeteaseXeapiTests（Node 逐字节对照、**deviceID 跨启动复用**、**Cookie 覆盖式合并**）/ MobileSessionsTests（取消登录、迟到账号、分页去重、失败重试与分页锁、**总数缺席仍能翻页**） |
| 其它 | ErrorSanitizationTests（**超时文案按平台分岔**：macOS=本地服务超时 / iOS=请求超时，均离线可测）/ LikedStateTests / DemoAudioGeneratorTests / PlayingSourceInfoTests / **AppStateLoginLoadTests**（`didLogin` 与 `restoreLoginState` 必须**各自**把喜欢的音乐 + 用户歌单拉起来；未登录不发请求；**会话失效后重新登录必须解除 `needsReLogin` 写禁用**、**退出/失效要清掉内存里的用户歌单**，否则下一个账号会看到上一个账号的歌单） |

全部用桩 Provider / 录制器，不联网、不写真实用户状态（`PlayerControllerTests` 会把持久化
重定向到临时目录，`SearchAssistStoreTests` 注入独立 UserDefaults suite）。
**真正联网的接口验证只能靠实机跑 App** —— 离线测试能证明「我们读的键名与接口约定一致」，
不能证明「接口真的返回了这些字段」。

> **可测性约定**：`project.yml` 把 `Features/**` 排除在测试 target 之外，
> 所以放在那里的 store 一个都测不到（`LibraryStore` / `SocialStore` 都是这么废掉的）。
> **有状态机的东西放 `Core/`** —— 照 `Core/Search/SearchSession.swift`、
> `Core/Comments/CommentsStore.swift` 与 `Core/Artist/ArtistProfileSession.swift`
> 的样子，纯逻辑在 `Core/`，SwiftUI 壳留在 `Features/`。

### eapi 向量的产生方式

`Tests/NeteaseEapiTests.swift` 里的期望密文由**仓库内打包的 Node 运行时**生成：

```bash
./ClearTone/Resources/HelperRuntime/bin/node your-script.js
# require api/util/crypto.js 的 eapi(uri, payload).params
```

重新启用直连路径或改动 eapi 相关代码后，应重跑对照，而不是手改期望值。

