# 澄音 ClearTone — 深度优化方案

> 状态：**已实施**（P0 全部、P1 大部分、P2 全部）。本文保留原始调研结论作为回溯依据，各条末尾标注了实施状态。
> 调研方式：三路并行只读代码审查（播放引擎 / 网络与 Provider / UI 状态与持久化），所有结论已由人工抽查复核，附 `文件:行号` 证据。
> 实施基线：`baseline-v0.1.0`（`1bb3af6`）→ 优化完成于 `058df6f`
>
> ## 追加：移除 iOS target
>
> 下文「iOS 移植」一节记录的 weapi 纯 Swift 实现**已被采纳并保留**，但
> `ClearToneiOS` 这个 target 本身**已删除** —— 它缺登录页、设置页、歌单详情页，
> 是一个不完整的第二交付面，继续留着只会让人误以为「两个平台都支持」。
>
> 随之清理的：`ClearTone/iOS/`（1144 行）、`Playback/ScenePhaseBridge.swift`、
> 各文件里的 `#if os(iOS)` 分支、`PlayerController.isForeground`（随
> `setScenePhase` 失去唯一写入方，变成死代码）。
>
> **刻意保留的**：`NeteaseDirectTransport` / `NeteaseCrypto` / `OrderedJSON` /
> `NeteaseEndpoint` 这套直连+加密层（1047 行）。理由不是「舍不得删」：
> 1. 它是唯一不依赖 Node 的实现，而 Node 打包进来有 169MB；
> 2. 加密链路已与 Node 标准答案逐字节对齐（`Tests/NeteaseEapiTests.swift`，18 项）；
> 3. `NeteaseEndpoint` 同时是**路由登记表**，
>    `testEveryRequestCallSiteIsMapped` 靠它保证不存在「调了但没登记」的路由
>    —— `/song/detail` 当初就是这么漏的。
>
> 详见 `docs/architecture.md` §6.2「已无生产调用方的代码」。

## 实施结果速览

| 批次 | 提交 | 内容 | 测试 |
|---|---|---|---|
| 第 1 批 | `639a793` | 纯机械：视图重建路径上的主线程读盘、重复实例、未用订阅 | 28 → 28 |
| 第 2 批 | `e6b039d` | Demo 音频移出主线程、队列持久化改后台合并写 | 28 → 33 |
| 第 3 批 | `36bee1f` | 缓存边界条件 + 网络层 P1-2/3/4/5 | 33 → 47 |
| 第 4 批 | `abc4a3f` | seek 拖动分离、高频状态脱离 `@Published` | 47 → 52 |
| Metal | `e547c67` | 真实降分辨率/降帧、消除每帧分配、GPU 背压 | 52 |
| 网络 | `058df6f` | 播放地址并发化 + 可达性探测记忆 | 52 → 52 |

**实测发现（比预估严重）**：优化前队列 3808 首、`queue.json` 1.8MB，**主线程每 5 秒一次 24.6ms 的编码 + 原子写**。这是「播放中每 5 秒卡一下」的确切原因，已通过 `PersistenceWriter` 移到后台合并写。

**写测试时抓到并修正的真实 bug**（3 个）：
1. WAV 头长度：把 RIFF 约定值（文件大小 - 8）当文件长度分配，导致每个文件少写 8 字节尾部截断
2. 缓存淘汰：`freed` 与按 `index` 实时重算的 `totalCacheBytes` 重复扣减，淘汰提前停止、缓存仍超上限
3. 缓存前缀失效：无 query 的键形如 `/likelist|auth`，只按 `?` 切分导致前缀永远匹配不上

**刻意未做**：`PlayerController.init` 的队列恢复异步化。实测解码 1.8MB 仅需 25.6ms（一次性），而该路径涉及「恢复上次播放位置」，异步化收益不抵回归风险。

### 尚未实施（按建议顺序）

| 条目 | 内容 | 状态 |
|---|---|---|
| P1-8 | `.buffering` 状态是纯死设计 | ✅ 已做 |
| P1-9 | 每首歌新建 `AVPlayer` | ✅ 已做（但引出回归，见下） |
| P1-26 | 用户歌单缓存有两个 owner | ✅ 已做 |
| P1-21 | 频谱接入音频 | **结论：不做**（见下） |
| P2-1..P2-13 | 见第四节 | ✅ 已做（P2-9 的 `AVAssetDownloadTask` 方案仍未采纳，见该条） |

### P1-21 频谱：结论是「不做」

`SpectrumProcessor`（vDSP 实数 FFT）已修好并有 8 条测试覆盖：实时线程零分配
（原实现每次约 70 次堆分配）、采样率按 ASBD 真实值换算（原硬编码 44100，
而缓存链路是 48000）、取最新帧而非最前帧。

但**接入音频的尝试已回退**。`MTAudioProcessingTap` 在纯 Swift 里无法安全实现：
`MTAudioProcessingTapStorage` 这个 C 结构体在 SDK 头文件里根本不存在，
`MTAudioProcessingTapGetStorage` 返回的是 `void**` 而非 handler 指针，
无法把 handler 安全传进音频实时线程；且在 KVO 回调里创建 tap 会触发音频管线
重新协商格式，对 48kHz OPUS/CAF 缓存文件不稳。

**结果：播放卡在「缓冲中」，缓存歌完全播不了。** 播放稳定优先于频谱，
故整个 tap 挂载路径已删除，只保留 FFT 处理器与测试。
若将来要做，建议改用 `AVAssetReader` 离线分析，不侵入实时播放链路。

---

## 两次导致「无法播放」的回归（重要教训）

### 回归 1：探测超时收紧（P1-1）

把 `isStreamReachable` 的 `timeoutInterval` 从 4s 收到 1.5s，
理由是「Range 1 字节探测不需要 4s 容忍」。

**错在哪**：只考虑了响应体大小，忽略 DNS + TLS 握手的冷启动开销。
**实测数据**（同一天就测过，却没用来支撑这个判断）：原图封面 1.66s、`/playlist/detail` 1.0s。
探测失败 → 完整播放地址被判死 → 退回 30 秒试听流。

**教训**：改动关键路径的超时/阈值前，先把当天已有的实测数据用上。

### 回归 2：复用 AVPlayer 时的观察者顺序（P1-9）

```swift
player.replaceCurrentItem(with: item)   // ← item 立刻开始加载
statusObserver = item.observe(\.status)  // ← 才挂 KVO，晚了一步
```

复用一个已热起来的 `AVPlayer` 时，`replaceCurrentItem` 会立即开始加载，
本地文件或热连接下 item 可能在 KVO 挂上之前就变成 `.readyToPlay`。
**KVO 不补发历史值** → `readyToPlay` 回调永远不送达 → `player.play()` 从不调用 → 没声音。

原先每次新建 AVPlayer 时 item 状态变化慢，观察者通常能抢赢，所以问题在改成复用后才暴露。

**正确顺序**：先确保 player 存在 → 挂齐所有观察者 → 最后 `replaceCurrentItem`；
交出 item 后再同步检查一次 `item.status` 兜底。

**教训**：「顺手做的优化」里最危险的是改变事件注册与事件触发的时序关系。

### 排查方法上的两个失误

1. **先入为主**：用户说「网络优化有问题」就直接去查网络，
   而没先确认「地址到底拿到了没有」。用日志里真实失败的歌曲 ID 复现，
   一次就看清了（`br=320000` 完整高音质 + 探测 206，地址完全可用）。
2. **缺少运行时证据**：崩溃报告与统一日志都查不到时，
   应该在关键状态转换处加临时诊断日志，而不是继续推断。

**下次遇到「某个功能坏了」：先用真实输入复现到具体环节，再动手改。**

### 调研中的误报（实施时发现，已排除）

写代码时被编译器/测试证伪，**不要按原方案改**：

| 条目 | 原结论 | 实际情况 |
|---|---|---|
| P1-15 | 缺 `AVAudioSession` 配置导致蓝牙/AirPlay 不可用 | **`AVAudioSession` 在 macOS 上不可用**（`unavailable in macOS`），那是 iOS API。macOS 输出路由由 CoreAudio 管理，AVPlayer 自动处理，无需配置 |
| P1-28 | `CoverImage` 占位符被擦除成 `AnyView`，列表行多一层动态树节点 | 7 处调用点**全部**用泛型 + 具体视图的尾随闭包形式，`Placeholder` 被推断为具体类型。`AnyView` 便利构造从未被调用（已删除以防误用） |

**写测试时抓到并修正的真实 bug（累计 4 个）**：
1. WAV 头长度：把 RIFF 约定值（文件大小 - 8）当文件长度分配，每个文件少写 8 字节尾部截断
2. 缓存淘汰：`freed` 与按 `index` 实时重算的 `totalCacheBytes` 重复扣减，淘汰提前停止、缓存仍超上限
3. 缓存前缀失效：无 query 的键形如 `/likelist|auth`，只按 `?` 切分导致前缀永远匹配不上
4. 随机历史双结构失同步：同一 id 重复入栈后弹一次就从集合删除，尽管栈里还有记录 → 该歌在应被排除时被重复抽中

---

## 一、结论摘要

代码的**资源生命周期管理是干净的**（观察者成对注册释放、闭包全 `[weak self]`、代次令牌 `loadToken` 竞态防护完整、列表 id 全部稳定、原子写盘）。真正的性能与可靠性问题高度集中在三条主线上：

| 主线 | 根因 | 典型症状 |
|---|---|---|
| **A. 主线程做 IO / 全量序列化** | `PersistenceStore` 与 `AudioCacheManager` 全部标 `@MainActor`，编码+落盘同步执行；`DemoProvider` 音频生成挂在 `App.init` | 启动白屏数秒；播放中每 5 秒卡一下；点红心掉帧 |
| **B. `@Published` 粒度过粗** | SwiftUI 对 `ObservableObject` 只订阅合并后的 `objectWillChange`，无属性级追踪 | `currentTime`/`bufferedTime` 每 0.5s 触发全窗口重算，100% 无可见变化 |
| **C. 缓存的边界条件缺失** | 容量无上限、无访问时间更新、无超时、无代次校验 | 内存单调增长；「常听的歌」反被淘汰；「缓存中」永久卡住；清除后幽灵条目复活 |

另有一类**"看起来在工作、实际是空实现"**的问题（Metal 节能模式、频谱分析器），会误导后续判断，需明确决策去留。

---

## 二、P0 — 必须修（可观测故障或严重卡顿）

### P0-1 启动时在主线程合成 6 个 Demo 音频文件

**证据**
```swift
// ClearToneApp.swift:12-14
init() {
    DemoProvider.generateDemoAudioIfNeeded()   // App.init，同步
}
```
```swift
// DemoProvider.swift:206-217
let frameCount = Int(sampleRate * duration)   // 44100 × 30 = 1,323,000
for i in 0..<frameCount { samples[i] = Float(sin(twoPi * freq * t) * 0.5) }
```
```swift
// DemoProvider.swift:269-271  逐 2 字节 append
for sample in samples { withUnsafeBytes(of: int16.littleEndian) { data.append(contentsOf: $0) } }
```

**影响** 首次启动在首帧前阻塞数秒：6 × 132 万样本、约 **530 万次 `sin()`**、6 次 5.3MB 数组分配、约 32MB 逐字节写入。表现为白屏 + 咖啡杯 + 可能被系统判为无响应。

**改法**
1. `generateDemoAudioIfNeeded()` 移出 `App.init`，改为 `.task { await DemoProvider.ensureDemoAudio() }` 在后台生成；或按需生成（首次播放 demo 歌曲时才生成那一个）。
2. `writeWAV` 改为一次性 `Data(count:)` + `withUnsafeMutableBytes` 批量写入，替代逐样本 `append`。
3. 合成前先检查文件是否存在且大小合理，存在则直接返回（避免每次启动都过一遍生成逻辑的入口判断）。

---

### P0-2 播放中每 5 秒在主线程全量重新编码整个队列并原子写盘

**证据**
```swift
// PlayerController.swift:268  每 0.5s 触发
self.persistProgressThrottled()
// PlayerController.swift:61
private let progressSaveInterval: TimeInterval = 5
// PlayerController.swift:521-533
let data = PersistedQueue(items: queue.items, ...)   // 整个队列
PersistenceStore.shared.saveQueue(data)              // 主线程 JSONEncoder + 原子写
```
`persistState()` 另被 `beginPlay`/`pause`/`seek`/`appendToQueue`/`insertNext`/`removeFromQueue`/`moveQueueItems`/`setRequestedQuality`/`stopPlayback` 共 10 处调用。「播放全部」一个 5000 首歌单 = 主线程一次性序列化约 2MB JSON。

**影响** 1000 首队列约 400KB JSON，**每 5 秒一次主线程冻结**。用户感知为进度条周期性顿挫。

**改法**
1. 新增 `actor PersistenceWriter`：`schedule(_:)` 合并写（`Task.sleep(800ms)` 抖动合并后在后台编码+落盘）；`flushNow()` 供退出时强制收尾。
2. **拆分持久化频率**（关键）：进度（`currentTime`）与队列结构（`items`）不该绑在同一个 5s 节流里。进度写 `UserDefaults` 或独立小文件可高频；队列结构只在真正变更时写一次。当前属于**过度持久化**。

---

### P0-3 Slider 逐像素触发 seek，零容差 + `Task.cancel` 无法撤回已提交 seek

**证据**
```swift
// PlayerBarView.swift:301
Slider(value: $value, in: 0...max(maximum, 1))   // 拖动中每帧触发 setter
// PlayerController.swift:383-397
public func seek(to time: TimeInterval) {
    seekTask?.cancel()
    isUserSeeking = true
    currentTime = time
    seekTask = Task {
        await player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        isUserSeeking = false
        if currentSong != nil { persistState() }   // 拖动中每像素触发全队列持久化
    }
}
```

**影响** 60–120Hz 提交零容差精确 seek。`.zero` 意味着不能用关键帧近似，必须从邻近关键帧重新解码。**`Task.cancel()` 不会撤回已提交给 AVFoundation 的 seek**，拖动过程中累积 N 个已提交请求 → 音频断续、耗电飙升、最终 `currentTime` 取决于哪个 completion 最后返回。`isUserSeeking` 会被任意一个（可能已取消的）旧 task 尾行置回 false。

**改法**
1. `ProgressSlider` 用 `onEditingChanged`（或 `DragGesture`）区分拖动/结束：
   - 拖动中 → `player.previewSeek(to:)`，容差 ±1s，只更新 `currentTime`，**不写 AVPlayer**；
   - 抬起 → `player.commitSeek(to:)`，零容差精确 seek + 持久化一次。
2. `seek` 加 ≥80ms 时间节流。
3. 用单调递增 `seekToken` 替代 `seekTask?.cancel()`，让 completion 只接受最新 token。

---

### P0-4 `bufferedTime` 高频 `@Published` 引发全 UI 树重绘，而唯一用途是一个 tooltip

**证据**
```swift
// PlayerController.swift:30
@Published public private(set) var bufferedTime: TimeInterval = 0
// PlayerController.swift:227-234  loadedTimeRanges 变动即写
// PlayerBarView.swift:297-303  唯一消费点
struct ProgressSlider { var buffered: TimeInterval
    var body: some View { Slider(...).help("已缓冲 \(Int(max(0, buffered))) 秒") } }
```

**影响** `PlayerController` 被 7 处 `@EnvironmentObject` 持有。SwiftUI 对 `ObservableObject` **无属性级追踪**，任意 `@Published` 变化都会让所有这些视图的整个 `body` 重算 —— 包括 `NowPlayingView` 的 `GeometryReader`、Metal `updateNSView`、整个 `LyricListView` 的 ForEach 差分。**这次重绘 100% 不产生任何可见变化。**

> 根因是 `PlayerController.swift:32-33` 注释声称要做、但从未落地的高频/低频分离：
> ```swift
> /// 高频时钟与低频 UI 状态分离：currentTime 更新通过 timer，view 按需订阅
> public let timePublisher = PassthroughSubject<TimeInterval, Never>()
> ```
> `timePublisher` **全项目 0 个订阅者**。

**改法**
1. 立即止血：把 `buffered` 参数从 `ProgressSlider` 删掉（tooltip 信息价值极低），`bufferedTime` 降级为非 `@Published` 的 `private(set) var`。
2. 根治：把 `currentTime` 与 `bufferedTime` 从 `@Published` 移出，视图侧 `onReceive(player.timePublisher)` 驱动本地 `@State`；`@Published` 只保留 `currentSong`/`playbackState`/`volume` 这类低频状态。
3. 长期：整体迁移 Observation 框架（`@Observable`），获得属性级依赖追踪。这是本项目收益最大的一次性重构，但改动面大，建议放在 P0/P1 收尾后单独立项。

---

### P0-5 响应缓存无容量上限（`pruneExpiredCache` 只删过期不删超量）

**证据**
```swift
// NeteaseProvider.swift:526-528
responseCache[cacheKey] = CacheEntry(data: data, expiresAt: Date().addingTimeInterval(ttl))
if responseCache.count > 256 { pruneExpiredCache() }
// NeteaseProvider.swift:562-565
private func pruneExpiredCache() {
    responseCache = responseCache.filter { $0.value.expiresAt > Date() }
}
```

**影响** 256 不是上限而是**触发阈值**。只要写入速率高于过期速率（歌词 TTL 1800s、播放地址 240s），字典单调增长：拉一个 1000 首歌单 = 10 页 × 约 150KB ≈ 1.5MB，翻 30 个歌单 ≈ **45MB 常驻**，最坏可达数百 MB 后被 jetsam 杀掉。附带成本：超过 256 后**每个写请求**都做一次 O(n) `filter`。`playlistTrackCache`(:207-210) 同理。

**改法** 加硬上限 + 字节预算，超限时按 `expiresAt` 升序淘汰最旧若干条；`playlistTrackCache` 改为 `>= 16` 时按 `cachedAt` 淘汰最旧 4 条。

---

### P0-6 `afconvert` 子进程无超时无取消，挂死则「缓存中」永久卡住并泄漏线程

**证据**
```swift
// AudioCacheManager.swift:198-227
try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global(qos: .utility).async {
        ...
        try process.run()
        process.waitUntilExit()      // 无限阻塞；Task.cancel() 不中断
        ...
    }
}
```
`cachingSongIDs` 的移除只在 `do`/`catch` 里（:70-98），无 `defer`、无看门狗。下载用 `URLSession.shared`（无 `timeoutIntervalForResource`）。

**影响** afconvert 对畸形输入挂死 → `waitUntilExit()` 永不返回 → continuation 永不 resume → **该 songID 永远留在 `cachingSongIDs`**（「缓存中」chip 永久显示）、一个 `.utility` 线程永久泄漏、`tmp-*.caf` 永久残留。下载卡死同理。

**改法**
1. 加 watchdog：`Task { try? await Task.sleep(.seconds(120)); if process.isRunning { process.terminate() } }`。注意 `CheckedContinuation` 只能 resume 一次，需 actor 或锁保护，避免 watchdog 与正常路径双 resume（会 crash）。
2. `URLSession.shared` 换成专用 `URLSessionConfiguration`，设 `timeoutIntervalForResource = 300`。
3. `cachingSongIDs` 清理移入 `defer`，并加「超过 N 分钟仍在 caching」的强制解锁看门狗。
4. 入口检查磁盘剩余空间（`URLResourceValues.volumeAvailableCapacityForImportantUsage`），不足时跳过并记日志。

---

### P0-7 缓存 `clearAll()` 与在途任务竞态 —— 清除后条目会「复活」

**证据**
```swift
// AudioCacheManager.swift:100-108
func clearAll() {
    cachedSongIDs.removeAll()
    cachingSongIDs.removeAll()   // 只清内存集合，不取消在途 Task
    index.removeAll()
    ... removeItem ...
}
// :75-90  Task 内无任何代次/取消检查
self.index[songID] = CacheMeta(...)   // 清除之后又写回来
```

**影响** 用户点「清除缓存」时若有歌曲正在转码，几十秒后「缓存占用」自己涨回去、幽灵记录重新出现且可播放。`cachingSongIDs.removeAll()` 还让「缓存中」chip 提前消失，用户以为已清干净。

**改法** 加 `clearGeneration` 计数器，`cacheInBackground` 的 Task 在写入索引前校验，失效则删除刚写的文件后返回。

---

### P0-8 所谓 LRU 实为 FIFO —— 访问时间从不更新

**证据**
```swift
// AudioCacheManager.swift:52-57
func cachedItem(for songID: String) -> CachedAudio? {
    guard let meta = index[songID] else { return nil }
    let url = fileURL(for: songID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }  // 只 stat，不更新访问时间
    return CachedAudio(url: url, ...)
}
```
淘汰按 `contentModificationDate` 排序，而 mtime 只在写入时设定。

**影响** **用户最常听的歌（最该留在缓存里的）恰恰是最早写入的，会被优先淘汰。** 直接症状：「明明常听的歌总是走网络」。

**改法** 二选一：
- `CacheMeta` 增加 `lastAccessedAt`，命中时若距上次访问 > 60s 则更新索引并延迟合并落盘；`trimIfNeeded` 改按此排序。
- 折中（零额外 IO）：播放缓存时 `setAttributes([.modificationDate: Date()], ...)` 触碰 mtime，保留现有排序逻辑。成本一次 `utimensat`。

---

### P0-9 `trimIfNeeded` 在主线程做 O(n log n) 次 `stat()` 系统调用

**证据**
```swift
// AudioCacheManager.swift:140-155
let sorted = files
    .filter { $0.pathExtension.lowercased() == "caf" }
    .sorted { lhs, rhs in
        let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return l < r                      // ← 比较器内逐次 stat
    }
```
且 `AudioCacheManager` 是 `@MainActor`（:12-13），由缓存完成回调（:91）调用。

**影响** 1.5GB / 96kbps ≈ 500 个 `.caf`，比较器最多调用 500 × log₂500 ≈ **4500 次 `stat()`**。因为比较器里有 IO，排序器无法优化，**主线程阻塞可达数百毫秒**，且恰好发生在「刚缓存完一首、准备切下一首」的用户感知敏感点。

**改法** `contentsOfDirectory(includingPropertiesForKeys:)` 已带回 `contentModificationDate`，**在循环外一次性取值再排序**，从 n·log n 次 stat 降到 n 次；顺带把 `fileSize` 一起取出来，与索引里的 `sizeBytes` 对账（当前 `totalCacheBytes` 用索引、排序用磁盘，两者可能不一致）。

---

## 三、P1 — 重要（状态错乱 / 明显浪费 / 隐性缺陷）

> ⚠️ **本节的「问题 / 证据 / 改法」三列在一次文档编辑事故中丢失**（脚本按表头匹配，
> 误伤了本节的第一张表）。下面只保留了能从本文其它地方考证到的条目与状态。
> 需要逐条重述时，请对着当前代码重新推导，不要凭记忆补。

| # | 状态 | 说明 |
|---|---|---|
| P1-1 | ✅ 已做 | 播放地址探测超时收紧。**这条引发过「无法播放」回归**，见「两次导致无法播放的回归」 |
| P1-2 ~ P1-6 | ✅ 已做 | 网络层。随 `36bee1f` 一批实施（缓存边界条件 + 网络层 P1-2/3/4/5）。P1-4 有「复发图标消失」风险 |
| P1-8 | ✅ 已做 | `.buffering` 是纯死设计 |
| P1-9 | ✅ 已做 | 每首歌新建 `AVPlayer` 改为复用单实例。**这条也引发过「无法播放」回归**（观察者注册时序），见「回归 2」 |
| P1-15 | ❌ 误报 | `AVAudioSession` 是 iOS API，macOS 上不可用。详见上文「调研中的误报」 |
| P1-21 | 🚫 不做 | 频谱接入音频：`MTAudioProcessingTapStorage` 不在 SDK 公开头文件里，挂 tap 会与 AVPlayer 重新协商音频格式、导致缓存的 OPUS 播不出来。详见「P1-21 频谱：结论是不做」 |
| P1-22 | ✅ 已做 | `@State` 初值 |
| P1-23 | ✅ 已做 | `DemoProvider.shared` |
| P1-24 | ✅ 已做 | 删除未使用的 `@EnvironmentObject` |
| P1-25 | ✅ 已做 | Sidebar / Discover 加 `loadToken` 竞态防护 |
| P1-26 | ✅ 已做 | 用户歌单缓存有两个 owner |
| P1-28 | ❌ 误报 | `CoverImage` 占位符并不会被擦除成 `AnyView`。详见上文「调研中的误报」 |
| P1-29 | ✅ 已做 | 启动读盘异步化 |
| P1-30 | ✅ 已做 | `storageURL` 由计算属性改为 `let`，建目录只做一次 |
| 其余编号 | 未记录 | P1-7、P1-10~P1-14、P1-16~P1-20、P1-27 的原始描述已随本节表格一并丢失 |

---

## 四、P2 — 次要与重构（不阻塞，择机做）

| # | 问题 | 证据 | 改法 | 状态 |
|---|---|---|---|---|
| P2-1 | `timePublisher` 是死代码（第 32 行注释描述的架构从未落地），误导后来者 | `PlayerController.swift:32-33` | 随 P0-4 一并处理，否则删掉 | ✅ 随 P0-4 落地，被 `PlaybackTimeObserver` 消费，不再是死代码 |
| P2-2 | `PlayerController.localProvider` 是从未使用的死对象 | `PlayerController.swift:45-46` | 删除或改 `LocalProvider.shared` | ✅ 删除（它构造的是一个没人用的新实例） |
| P2-3 | `AmbientBackgroundRenderer.pause()/resume()` 死代码 | `AmbientBackgroundRenderer.swift:66-72` | 随 P1-17 接入 | ✅ 删除。暂停已由 SwiftUI 侧 `isAnimating`（绑 `scenePhase`）→ `MTKView.isPaused` 承担 |
| P2-4 | 对 `ScrollView` 使用了 `List` 专属修饰符（无效代码，`scrollContentBackground` 失效意味着背景可能不透明） | 原 `MainWindow.swift:503-504` | 删除；需要透明背景就加 `.background(Color.clear)` | ✅ 现存 12 处 `scrollContentBackground` 全部挂在 `List` 上，无效用法已清零 |
| P2-5 | `MusicError` 缺 `Equatable`，且 `case unknown(String)` 丢弃底层 `Error`（无法做 `URLError` 判定），`localizedDescription` 随系统语言变化不利于测试断言 | `MusicError.swift:3`、`NeteaseProvider.swift:536` | 改 `case unknown(underlying:message:)`，加 `Equatable` 或 `isRetryable` | ✅ `Equatable` + `from(_:)` 归一化 `URLError` + `isRetryable`。**没有**改成 `unknown(underlying:message:)`：`Error` 不可 `Equatable`，那样就拿不到本条想要的 `Equatable`；底层语义改由 `from(_:)` 映射到具体 case |
| P2-6 | **错误信息原样透传到 UI 不经脱敏**：`MusicError.unknown(error.localizedDescription)` 与 `.apiError(message:)` 把服务端 message 直接给界面 | `NeteaseProvider.swift:536, 466, 516` | 在 `MusicError` 出口统一 `CTLog.sanitize`。同时扩展脱敏正则（当前只认 `key=value`，不认 JSON 的 `"MUSIC_U":"..."`，且漏 `MUSIC_A`/`__remember_me`） | ✅ 正则扩到 JSON / query / header 三种形态，补 `MUSIC_A`/`MUSIC_R`/`__remember_me`/`authorization`。`Authorization: Bearer <jwt>` 的值含空格，单列一条规则 —— 否则只抹掉 `Bearer`、JWT 整段留存。新增 `Error.ctUserMessage` 作为 UI 唯一出口，29 处改走它 |
| P2-7 | 崩溃/强杀后 `tmp-*.caf` 成为永久孤儿，并因扩展名是 `.caf` 被写进正式索引 | `AudioCacheManager.swift:178-180, 131-137` | `refreshIndex()` 末尾清扫 `tmp-` 前缀文件；`tmp-` 提取为常量 | ✅ |
| P2-8 | `trimIfNeeded` 可能删掉**正在播放**的缓存文件（它 mtime 最旧，APFS 上已开 fd 可继续读但有窗口期失败） | `AudioCacheManager.swift:140-161` | 淘汰时跳过 `currentCachedSongID` | ✅ |
| P2-9 | 缓存任务与播放流**双倍带宽**（同一 URL 下载两遍），且无并发/限速控制，会与播放抢连接池 | `PlayerController.swift:175-182`、`AudioCacheManager.swift:170` | 改用 `AVAssetDownloadTask`（复用分片，省一半流量）；或至少限制缓存并发为 1 + `httpMaximumConnectionsPerHost = 2` | ⚠️ 部分。`httpMaximumConnectionsPerHost = 2` 与专用 session 已就位；新增**串行缓存队列** —— 原先连切 30 首歌会同时跑 30 个下载 + 30 个 afconvert 进程。**仍未做**：`AVAssetDownloadTask` 复用分片 |
| P2-10 | `SearchField` 本地文本与 `appState.searchQuery` 不双向同步，切走再切回输入框被清空 | 原 `MainWindow.swift:204, 212-216` | `TextField(text: $appState.searchQuery)`，或 `onChange(currentPage)` 回填 | ✅ |
| P2-11 | 原 `MainWindow.swift` 906 行塞了 15 个 View + 1 个 Loader，同时含网络加载/缓存读写/导航/头像缓存四种关注点 | `MainWindow.swift` 全文 | 按现有 `Features/` 目录拆成 7~8 个文件 | ✅ 1580 → 386 行，拆出 `Features/Discover/DiscoverView.swift`、`Features/Library/{MyMusicView,LikedView,LocalMusicView,RecentView}.swift`、`Features/Playlist/PlaylistDetailView.swift` |
| P2-12 | `AvatarLoader` 与 `CoverLoader` 逻辑高度重复（都是 URLSession + NSCache + 下采样），`AvatarLoader` 还没走去重/磁盘缓存 | 原 `MainWindow.swift:263-286`、`CoverImage.swift:68-145` | 合并为一个 loader，`AvatarView` 复用其缓存；删 `AvatarLoader` | ✅ 删除 `AvatarLoader`，头像走 `CoverLoader.avatar(url:pointSize:)`，因此获得在途去重、磁盘缓存、不可达 host 换镜像重试。顺带把两条**手抄绘制逻辑、断言自己刚建的 rep** 的假测试改成调用真实实现并断言四角透明/中心不透明 |
| P2-13 | 恢复队列时 `currentIndex` 只做上限夹取，下限未处理（`items` 为空时为 -1） | `PlayerController.swift:550` | 夹取到 `0...max(0, count-1)` | ✅ |

---


## 五、已正确处理（不要动）

调研中反复确认这些是对的，列出以免后续"优化"时被误伤：

- **列表 id 全部稳定**：`Song`/`Playlist` 都是 `Identifiable` 且 id 为不可变 `String`；所有列表用 `List(songs)`/`ForEach(x)`，无 `id: \.self`、无索引 id。1000+ 首不会因 id 错乱或全量重建。
- **懒加载选型正确**：歌曲行用 `List`（NSTableView 支撑、按需实例化），卡片网格用 `ScrollView + LazyVGrid`，没有一次性构造全部行的写法。
- **`@StateObject` 注入单例写法正确**（autoclosure 只求值一次），`ClearToneApp.swift:6-9`。
- **代次令牌竞态防护**：`PlaylistDetailView`（`:776-778, 869-871, 893`）与 `MyMusicView`（`:466-467, 511-533`）的 `loadToken` 写得完整（含 `Task.isCancelled` 校验），**是本项目最值得复制的范式**。
- **分页边到边追加**：先渲染首屏再增量追加，每批校验 token。
- **`PersistenceStore` 原子写**：`.atomic`，崩溃/断电不留半截 JSON。
- **Provider 侧零日志**：cookie 只走 `X-CT-Cookie` 头，不进 URL、不进日志；Node 侧 `server.js:219-224` 也把 cookie 注入 `req.query` 而非 URL → `helper.log` 不会出现 cookie。
- **Helper 安全模型**：仅监听 127.0.0.1、随机端口、随机 UUID token、Cookie 走 header、随父进程退出。
- **封面 `?param=` 裁剪 + 内存缓存 + 在途去重**（`CoverImage.swift:96-126`），服务端裁剪已生效。

---

## 六、建议执行顺序

按「收益/风险比」分四批，每批独立可验证、可回滚：

**第 1 批 — 纯机械，无行为变更**（预计 1~2 小时）
P1-22 `@State` 初值 · P1-23 `DemoProvider.shared` · P1-24 删除未用 `@EnvironmentObject` · P1-25 Sidebar/Discover 加 `loadToken` · P1-30 `storageURL` 改 `let` · P2-4 删除无效修饰符 · P2-13 `currentIndex` 下限
> 验证：build + 28 测试通过；播放时切页无掉帧

**第 2 批 — 启动与持久化**（预计半天）
P0-1 Demo 音频移出主线程 · P0-2 `PersistenceWriter` + 拆分持久化频率 · P1-29 启动读盘异步化
> 验证：首帧时间（`os_signpost` 或 Instruments App Launch）；播放中 5 分钟无周期性顿挫

**第 3 批 — 缓存边界条件**（预计 1 天）
P0-5 缓存硬上限 · P0-6 afconvert 超时与 defer · P0-7 `clearGeneration` · P0-8 真 LRU · P0-9 排序 stat 降为 n 次 · P2-7 清理 tmp 孤儿 · P2-8 保护正在播放的文件
> 验证：单元测试覆盖（缓存上限、clearAll 竞态、LRU 顺序）；跑 afconvert 挂死用例验证 watchdog

**第 4 批 — 高频状态与 seek**（预计 1 天，风险最高）
P0-3 seek 分离 preview/commit · P0-4 `bufferedTime` 降级 + `timePublisher` 落地
> 验证：拖动进度条听感无断续；Instruments 观察 SwiftUI body 求值次数下降
> **注意**：这条会改动 `PlayerController` 的公开 API 语义，需同步改 3 处 `ProgressSlider` 调用点

**独立立项 — Observation 迁移**
把 `PlayerController`/`AppState` 迁到 `@Observable`，从根本上解决「一个属性变化全树重绘」。收益最大但改动面最大，建议在上述四批全部收尾、行为稳定后再做。

**网络层**（P1-1~P1-6）可与上述并行，优先级低于 P0-4 的止血部分，但 P1-4 有**复发图标消失 bug** 的风险，建议尽早做。

---

## 七、明确不做 / 待决策

| 项 | 说明 |
|---|---|
| 真实频谱 | `SpectrumAnalyzer` 当前是死代码。`MTAudioProcessingTap` 对 HTTPS 流媒体支持有限是真实限制。**需决策**：只对本地/缓存文件接上，还是整体删掉保留环境动画。不要维持现状（占代码、会误导） |
| YRC 逐字歌词 | 现只有 LRC 逐行。YRC 需解析 `yrc` 格式并做时间轴对齐，工作量独立 |
| Artist/Album 详情页 | 搜索结果里点歌手/专辑无落地页 |
| 自定义 API 服务器 | 设置项未接线 |
| 菜单栏模式 | 未实现 |
| 扫码登录 | 受网易云风控限制（手机报「设备环境异常」），已做 loopback IP 与 `randomCNIP` 修复但无效。**不在代码可解决范围内** |

---

## 八、验证方法建议

- **启动耗时**：`os_signpost` 包裹 `App.init` / `PlayerController.init` / `AppState.init`，或用 Instruments 的 App Launch 模板看首帧时间
- **主线程 IO**：Instruments 的 **Time Profiler** 勾选 File Activity，或 `fs_usage` 看是否有主线程 write
- **SwiftUI 重绘**：Signpost 打点各视图 `body` 入口，统计 `currentTime` tick 期间的求值次数（应从 2Hz×全树 降到 0）
- **缓存行为**：单元测试覆盖 P0-5/P0-7/P0-8；afconvert 挂死用 `kill -STOP` 模拟
- **回归**：`xcodebuild -project ClearTone.xcodeproj -scheme ClearTone -configuration Debug test -destination 'platform=macOS'`，当前 28 项全绿，各批次均需保持

---

## 电台功能：已知限制

功能已可用（实测：`/dj/recommend` → `/dj/program?rid=` → 播放走标准链路）。

| 限制 | 原因 |
|---|---|
| 节目只加载单页 30 期 | 未做无限滚动。`/dj/program` 支持 `offset` 分页，接口层面已具备 |
| 电台名称显示为「电台」 | `/dj/detail` 需登录态且部分电台返回 400，不稳定；为不阻塞节目展示用兜底名。若要真实名称，可在拉节目时并行查一次热门/推荐列表做匹配 |
| 不支持订阅电台 | `/dj/sub` 是写操作。鉴于 `/like` 曾因 GET/POST 用错被网易云判为风控（见下），写操作在实测确认请求方法前不盲写 |
| 节目仅显示可播放的 | `mainSong` 缺失的条目会被过滤，避免点了没声音 |

## 写操作必须实测请求方法（重要）

`/like` 长期用 GET 调用，网易云稳定返回 `code: 524「当前环境异常，已取消喜欢」`，
表现为「点收藏完全没反应」。同一首歌、同一 cookie、同一个 helper 进程：

    POST /like → code 200
    GET  /like → code 524

`NeteaseProvider.request()` 原先从不设置 `httpMethod`，URLRequest 默认 GET，
所以项目第一天起所有写操作都是 GET 出去的。

**约定**：新增任何写接口（订阅、评论、加歌单）前，
先用 curl 分别试 GET 和 POST，确认哪个返回 200，再写代码。

    curl -s -X POST -H "X-CT-Cookie: $COOKIE" -d "id=123&like=true" "$H/like"

## 封面下载慢的真实原因

瓶颈是**连接建立**，不是带宽。同一张封面的路径部分在所有 host 上通用，但可达性随机：

    p1/p2/p3 → HTTP 200,  0.66s
    p4/p7/p8 → TCP 连不上, 6s 超时（time_connect = 0）

DNS 随机解析到不可达节点，随机命中就表现为「封面一直不出来」。
`?param=` 对耗时几乎无影响（0.66s vs 0.68s）但体积差 3 倍（3955B vs 8680B），
所以 `?param=` 保留用于省流量，解决慢靠：超时压到 2.5s + 失败换 host 重试。

---

## iOS 移植：weapi 纯 Swift 可行性验证（已通过）

目标：确认网易云 weapi 加密能在 iOS 可用原语下跑通，否则 iOS 移植没有意义。
验证方式：独立 Swift 程序（/tmp/weapitest/），逐层对 Node 侧标准答案，不猜。

### 算法（从 api/util/crypto.js + node-forge 源码逐行读出）

weapi(obj):
  text      = JSON.stringify(obj)                      # 紧凑无空格
  secretKey = 16 个 base62 随机字符
  inner     = AES-128-CBC-PKCS7(text, presetKey, iv) → base64 字符串
  params    = AES-128-CBC-PKCS7(inner, secretKey, iv) → base64 字符串
              # 注意：外层加密的是内层 base64「字符串的 UTF-8 字节」
  encSecKey = hex(rawRSA(reverse(secretKey)))

presetKey = '0CoJUm6Qyw8W8jud'，iv = '0102030405060708'，RSA 公钥 1024 位、e=65537。

### 三个决定实现方式的细节

1. **双重 AES-CBC**：内层输出 base64 字符串，外层加密该字符串的 UTF-8。
2. **raw RSA，零 padding**：node-forge 的 `encrypt(str, 'NONE')` 里
   scheme.encode 是恒等函数。所以 Security.framework 做不到
   （只支持 PKCS1v15/OAEP），必须手写 bignum 模幂。
   输入左补零到 128 字节（大端），输出同样补齐到 128 字节再 hex。
3. **请求体必须对标 URLSearchParams 编码**：base64 里的 `+` 必须编成 `%2B`。
   URLComponents 的 urlQueryAllowed 不编码 `+`，直接用会导致服务端
   把 `+` 解成空格 → 返回 HTTP 200 空 body（极具迷惑性）。
   症状：HTTP 200 但 body 为空，不是 4xx。

### 验证结果（每层都对过标准答案）

- raw RSA：3 组 Node 生成向量全部一致
- 双重 AES：与 CryptoJS 输出逐字节一致
- 真实请求：POST https://music.163.com/weapi/v3/discovery/recommend/songs
  → HTTP 200，34 首日推

### iOS 可用的原语对照

  AES-128-CBC+PKCS7 → CommonCrypto（注意 Swift 6 下嵌套闭包排他性检查，
                       用 NSData/NSMutableData 写法避开）
  模幂/大整数       → 手写约 120 行（schoolbook 乘法 + 二进制长除法求余，
                       e=65537 只需 17 次平方，1024 位规模下毫秒级）
  注意：UInt64 减法下溢在 Swift 里会 trap，必须用 &-（曾因此 SIGTRAP）

### 结论

加密层不是 iOS 移植的障碍。真正的剩余工作是 UI/播放层的平台适配，
以及 12 个明文接口换 URLSession（零加密成本）。

---

## iOS 移植

### 为什么必须重写网络层

macOS 版通过本地 Node.js 辅助进程（api-enhanced，169MB）访问网易云。
iOS 上这条路完全不可用：

- **没有 `Process()`**，无法拉起子进程
- `bin/node` 是 macOS Mach-O 二进制（104MB），iOS 无法运行

所以 26 个接口全部要改成 Swift 原生实现。实测 21 个接口，20 个 code 200。

### weapi 加密（已逐字节验证）

`ClearTone/Providers/Netease/NeteaseCrypto.swift`。三个决定实现方式的细节：

1. **双重 AES-CBC** —— 外层加密的是内层 base64 *字符串的 UTF-8*，
   不是内层密文字节。
2. **raw RSA，零 padding** —— api-enhanced 用 `forge.encrypt(str,'NONE')`，
   node-forge 在该分支的 `scheme.encode` 是恒等函数。所以 Security.framework
   做不到（只支持 PKCS1v15/OAEP），必须手写 bignum 模幂（约 120 行）。
3. **表单编码对标 URLSearchParams** —— base64 的 `+` 必须编成 `%2B`，
   否则**HTTP 200 但 body 为空**（不是 4xx，极难定位）。

验证方式：先从 Node 侧（node-forge / CryptoJS）生成标准答案，
再让 Swift 逐字节对齐，而不是按协议文档手算。

### 顺带修正了一个误判

`/like` 收藏接口此前返回 -460 / 524，我当时记为「GET 方法不对」。
**实际原因是缺少客户端标识 cookie**（os / appver / osver / versioncode 等）。
补齐后进入正常风控（405「操作频繁」= 请求已被接受）。

结论要记住：-460 = 缺客户端标识；524 = 同一个原因的不同表现；
405 = 已被接受的风控限流。写操作确实要 POST，但方法不是唯一原因。

### 平台拆分

- `AppState` 从 `ClearToneApp.swift` 拆出（原本与 macOS AppDelegate 混在一起）
- `PlayerController` 用 `typealias PlatformImage` 跨平台
- `AudioCacheManager`：iOS 无 `Process()`，改用 `AVAssetExportSession`
  （不支持 OPUS，缓存为 AAC m4a，扩展名随平台变）
- `CoverLoader`：`NSImage` → `UIImage`，iOS 版复刻了 https 升级与 host 故障转移
- `project.yml` 两个 target 的 sources 需分别维护。**注意**：
  共享文件时不能给一个 target exclude 而另一个不 exclude，
  否则会出 `cannot find type` 或 `invalid redeclaration`。
