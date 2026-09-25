# 澄音 ClearTone — 深度优化方案

> 状态：**已实施**（P0 全部、P1 大部分、P2 少量）。本文保留原始调研结论作为回溯依据，各条末尾标注了实施状态。
> 调研方式：三路并行只读代码审查（播放引擎 / 网络与 Provider / UI 状态与持久化），所有结论已由人工抽查复核，附 `文件:行号` 证据。
> 实施基线：`baseline-v0.1.0`（`1bb3af6`）→ 优化完成于 `058df6f`

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
| P1-7 | **加载期暂停会静默丢弃「恢复播放位置」**；且切歌后立刻暂停时系统媒体控制仍显示上一首的标题封面 | 待做（用户可感知 bug） |
| P1-9 | 每首歌新建 `AVPlayer`，而非复用 + `replaceCurrentItem` | 待做（收益中等，风险中等） |
| P1-13 | `duration` 不与 `AVPlayerItem.duration` 校对，元数据不准时进度条最大值会错 | 待做（收益小，风险小） |
| P1-14 | 随机播放 `shuffleHistory` 是数组，`contains` 线性扫描，`next()` 为 O(n×k) | 待做（收益小） |
| P1-15 | 完全没有 `AVAudioSession` 配置，蓝牙/AirPlay 路由在部分配置下不可用 | 待做（功能缺失） |
| P1-8 | `.buffering` 状态是纯死设计，无 `playbackStalled` / `timeControlStatus` 观察 | 待做（依赖 P1-7） |
| P1-21 | 频谱分析器是死代码（`attach(to:)` 无条件 throw，无实例化点），且内部有 70 次/buffer 堆分配、采样率硬编码 44100（实际链路 48000） | **需决策**：接上还是删除 |
| P1-26 | 用户歌单缓存有两个 owner（`SidebarView` 与 `MyMusicView` 各存一份） | 待做 |
| P1-27 | `CoverLoader` 的 `NSCache` 只限数量不限体积，360×360 封面约 150MB 常驻 | 待做（收益小） |
| P1-28 | `CoverImage` 占位符被擦除成 `AnyView`，列表行多一层动态树节点 | 待做（收益小） |
| P2-2/3/5/6/7/8/9/10/11/12/13 | 见第四节，均为次要项 | 未做 |

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

### 网络与 Provider

| # | 问题 | 证据 | 改法 |
|---|---|---|---|
| P1-1 | **播放地址获取最坏 57–72 秒才出声**。`unm`/`gdmusic` 两源串行，每源 1 次 API(15s 超时) + 1 次探测(4s)；`try?` 吞错后仍要等满超时才进下一路 | `NeteaseProvider.swift:359-366, 398` | 两源改 `async let` 并发；探测结果做短 TTL 记忆（避免缓存命中也付 4s）；整条链路加总预算（8s）超时兜底；标准信道探测超时 4s → 1.5s（Range 1 字节探测不需要 4s 容忍） |
| P1-2 | **cacheKey 不含身份指纹**，只带 `hasCookie` 布尔值。不同账号共用同一缓存键，最长 240s 内音质/试听判定错误 | `NeteaseProvider.swift:555-560, 491` | cacheKey 纳入 cookie 的 SHA256 前 8 位；`sessionExpiredError()` 内同时 `clearCache()`（当前会话失效只清 `PersistenceStore`，**不清 `responseCache`**） |
| P1-3 | **`likeSong` 只失效一半缓存**，漏 `/song/detail`（TTL 300s），取消收藏后歌单曲目元数据最长 5 分钟不更新 | `NeteaseProvider.swift:461-469` | `invalidateCache` 改为接收前缀数组，`/like` 成功后失效 `["/likelist", "/song/detail", "/user/playlist"]`；`hasPrefix` 改为 `== \|\| hasPrefix(prefix + "/")` 防误伤 |
| P1-4 | **健康检查用 `URLSession.shared`，会重新创建 `~/Library/HTTPStorages/com.cleartone.app/`** —— 正是刚修好的图标消失问题的根因，会复发。稳态每 15s 一次完整 HTTP，启动期 300ms×15s 最多 50 次 | `HelperProcessManager.swift:229-235, 241, 215` | 换 `.ephemeral` 专用 session（`httpCookieStorage = nil`）；启动期轮询 300ms → 500ms，稳态 15s → 30s |
| P1-5 | **`helper.log` 无轮转**，运行期只追加。Node 对每个请求打 INFO（含 ANSI 色码），崩溃重启循环还会重开句柄而不 close 旧的 | `HelperProcessManager.swift:106-111, 121-127` | 启动时按 5MB 阈值轮转 `.1`；句柄登记在 `cleanup()` 统一 close；Node 侧生产环境日志级别降到 `error` |
| P1-6 | 健康检查把「401 鉴权失败」与「进程死亡」同等对待 → 理论上的**无限重启循环**（每 16s 拉起一个新 Node）。`MusicError.helperAuthFailed` 全项目从未被抛出 | `HelperProcessManager.swift:234, 245-250` | `checkPort` 区分 401 抛 `helperAuthFailed`，监控循环对该错误只记日志不重启；或加连续失败计数上限 |

### 播放引擎

| # | 问题 | 证据 | 改法 |
|---|---|---|---|
| P1-7 | **加载期暂停会静默丢弃「恢复播放位置」**。`pause()` 把状态改成 `.paused`，而 `startAudio` 只在 `case .loading` 分支执行恢复 seek → 从头开始播。**且切歌后立刻暂停时，系统媒体控制显示上一首的标题和封面**（`updateNowPlayingInfo` 只在 `startAudio` 内调用） | `PlayerController.swift:208-224, 307-318, 276-297` | `startAudio` 触发条件从「状态枚举 == .loading」改为「`playerItem === item` 且 `playbackState.songID == songID`」——只校验代次与 item 身份 |
| P1-8 | **`.buffering` 状态是纯死设计**：`PlayQueue.swift:10` 声明后全项目零赋值。无 `playbackStalled` / `timeControlStatus` 观察 → 网络抖动时界面无任何缓冲提示 | `PlayQueue.swift:10`、`PlayerController.swift` 全文 | 观察 `AVPlayerItemPlaybackStalled` 通知 + `timeControlStatus` KVO，在 `cleanupPlayer()` 中对称移除 |
| P1-9 | **每首歌新建一个 `AVPlayer`** 而非复用 + `replaceCurrentItem`，每次重建解码器协商，曲目切换有延迟尖峰，也让无缝切歌不可能实现 | `PlayerController.swift:198-203` | `player` 懒建一次并保留；`cleanupPlayer()` 拆为 `detachItem()`（换歌）与 `teardownPlayer()`（退出） |
| P1-10 | **封面在主线程解码 + 无缓存 + 无取消**。`updateNowPlayingInfo` 内 `Task {}` 继承 MainActor，307KB 原图解码 10–30ms；同一封面反复下载；快速切歌 10 次会有 10 个并发下载都跑完 | `PlayerController.swift:662-673` | 改用 `CoverLoader.shared.load(url:pointSize:600)`（已有 NSCache + URLCache + 在途去重），并把下载放进可取消的 `Task` 属性 |
| P1-11 | **每 0.5s 一次到 mediaremote 的 XPC**：`updateNowPlayingElapsedTime()` 写 `nowPlayingInfo` 字典触发 COW + 序列化 + XPC。系统本就能用 `PlaybackRate` 自行外推 | `PlayerController.swift:260, 676-678` | 从 timeObserver 里删除，只在 seek 完成后调用一次 |
| P1-12 | **`MPRemoteCommandCenter` 的 target token 从不保存、从不移除**。当前被单例掩盖，但测试反复访问 `PlayerController.shared`，将来重建实例会导致同一按键触发 N 次 | `PlayerController.swift:614-641`（无 `deinit`） | 存 `remoteCommandTokens: [Any]`，`deinit` 里 `removeTarget` |
| P1-13 | **`duration` 从不与 `AVPlayerItem.duration` 校对**，只信 API 元数据。本地文件或 CDN 转码流时长不准时，进度条最大值会错（拖到 99% 提前结束） | `PlayerController.swift:146, 556` | `.readyToPlay` 时读 `item.duration.seconds`，偏差 > 0.5s 则以实际值为准 |
| P1-14 | 随机播放 `shuffleHistory` 是数组，`contains` 线性扫描，`next()` 是 O(n×k)。1000 首时约 10⁶ 次 UUID 比较 | `PlayQueue.swift:55, 172-181` | 改 `Set<UUID>`（O(1) 查）+ `[UUID]` 栈（供 `previous()` LIFO 回退） |
| P1-15 | **完全没有 `AVAudioSession` 配置**（全项目零命中）。不设 `.playback` 类别时按 `.soloAmbient` 处理，限制到内建输出，蓝牙/AirPlay 路由在部分配置下不可用 | 全仓 `rg` 零命中 | `PlayerController.init` 设 `setCategory(.playback)`，停止时 `setActive(false, .notifyOthersOnDeactivation)`。注意不要在非主线程调用 |

### Metal 渲染（整块目前基本是空实现）

| # | 问题 | 证据 | 改法 |
|---|---|---|---|
| P1-16 | **「节能模式」是装饰性的**。`renderScale` 从未作用于 `view.drawableSize`，在 shader 里只用来缩放 UV 坐标 → **渲染像素量与全分辨率 100% 相同，GPU 成本零节省**。0.3 档与 0.6 档性能完全等价 | `AmbientBackgroundRenderer.swift:24, 89-92`（降帧块**空函数体**）、`Shaders.metal:41-42` | `updateNSView` 里按 `renderScale` 设 `drawableSize`（`autoResizeDrawable = false`），像素量降到 `scale²`（0.3 档 ≈ 9%）；shader 里 `scaledUV` 改 `uv / renderScale` 补偿坐标 |
| P1-17 | **`isAnimating` 永不变为 `false`**（`NowPlayingView.swift:26` 声明后全项目零赋值），`preferredFramesPerSecond = 60` 恒定。打开正在播放页后，**即使 App 在后台或窗口不可见，Metal 循环也不停** | `NowPlayingView.swift:26`、`AmbientBackgroundRenderer.swift:159-169` | 接到 `.onDisappear` / `scenePhase`；`preferredFramesPerSecond` 接到 `performanceMode`（saver 20 / auto 30 / quality 60） |
| P1-18 | **每帧 2 次堆分配**（`+= Array(repeating:)` 在 `colors.count < 5` 时**每帧都走**）= 60fps × 2 = **每秒 120 次分配** | `AmbientBackgroundRenderer.swift:111-125` | 持有预分配的定长存储（tuple / 预填 64 长度数组），`updateNSView` 时拷贝进来，`draw` 时零分配 |
| P1-19 | **command buffer 无背压**：从不 `waitUntilCompleted`、不查 GPU 状态。GPU 持续慢于 60fps 时队列无限堆积，**显存单调增长**直到被内存压力杀掉 | `AmbientBackgroundRenderer.swift:130-131` | 维护在途计数，`addCompletedHandler` 递减，超过 2 帧就跳过一帧；`framebufferOnly` 改回 `true` |
| P1-20 | `MTLCreateSystemDefaultDevice()` 创建两次（renderer 内 + `makeNSView`），多 GPU 配置下可能 device 不一致 | `AmbientBackgroundRenderer.swift:30, 161` | device 作为 `Coordinator` 属性，`makeNSView` 复用同一实例 |
| P1-21 | **频谱分析器是死代码**：`attach(to:)` 无条件 `throw`，全项目无实例化点。`NowPlayingView` 的 `spectrum` 永远是全零数组。且内部有 70 次/buffer 堆分配、采样率硬编码 44100（实际链路是 48000） | `SpectrumAnalyzer.swift:33-37, 40-63, 75` | **需决策**：要么删掉整个文件，要么对 `.local`/`.demo`/缓存文件真正接上 `MTAudioProcessingTap`。若接：`vDSP_fft_zrip` 实数 FFT（省一半运算）、缓冲区预分配复用、采样率从 `buffer.format.sampleRate` 读、取最新 1024 帧而非最前 1024 帧 |

### UI 与持久化

| # | 问题 | 证据 | 改法 |
|---|---|---|---|
| P1-22 | **`@State` 初始值里同步读盘 + JSON 解码，且每次 View 重建都重跑**。`@State` 默认值表达式在每次 View 结构体构造时求值（只有第一次结果被保留）。`MainWindow.body` 每次构造 `SidebarView()`/`MyMusicView()`，而 MainWindow 因 P0-4 每 0.5s 重建一次 → **播放中每 0.5s 白做 2 次 UserDefaults 读 + decode** | `MainWindow.swift:62, 462` | 初值改空数组，读取搬进 `.task`（先读缓存再拉网络） |
| P1-23 | **`DemoProvider` 没有 `shared`**，三处 `private let demoProvider = DemoProvider()` 在每次 View 重建时新建 actor 实例并执行一次 mkdir + 20 个 Song 分配 | `DemoProvider.swift:4, 11, 14, 86`、`MainWindow.swift:372, 585, 781` | 加 `public static let shared`，三处改用它（与 `NeteaseProvider.shared`/`LocalProvider.shared` 策略一致） |
| P1-24 | **7 处 `@EnvironmentObject var player` 中至少 3 处根本不用它**（`MainWindow:7`、`:169` ToolbarView、`:366` DiscoverView），白白订阅 0.5s 粒度的 `objectWillChange` | `MainWindow.swift:7, 169, 366` | 删除未使用声明；`:7`/`:50-52` 的重复注入也可删（sheet 自动继承 environment） |
| P1-25 | **`SidebarView.loadPlaylists()` 缺代次令牌**（同文件另两处已修）→ 切账号/演示模式后旧请求返回会**串出上一个账号的歌单**并污染缓存 | `MainWindow.swift:145, 148-163`；对比 `:466-467`、`:776-778` | 照抄 `PlaylistDetailView` 的 `loadToken` 写法。`DiscoverView.loadRecommendations()`(:409-417) 同样缺失，一并加 |
| P1-26 | **用户歌单缓存有两个 owner**（`SidebarView` 与 `MyMusicView` 各存一份 `userPlaylists`，读同一 key 写同一 key），可能显示不同内容、同一份数据解码两次写两次 | `MainWindow.swift:62/157`、`:462/526` | 提升为 `AppState` 的 `@Published private(set) userPlaylists` + 带 token 守卫的加载方法 |
| P1-27 | **`CoverLoader` 的 `NSCache` 只限数量不限体积**：`countLimit = 300` 且 `setObject` 不传 cost。360×360 BGRA 约 0.5MB/张 → **约 150MB 常驻**；且 NSCache 在内存压力下会整体清空（一次清空 = 全列表封面重下） | `CoverImage.swift:78, 111, 130` | 设 `totalCostLimit = 64MB`，`setObject` 传 `w*h*4` 作 cost；`countLimit` 降到 120 |
| P1-28 | `CoverImage` 占位符被类型擦除成 `AnyView`，热点列表行每张封面多一层动态树节点，行 diff 变慢 | `CoverImage.swift:43, 53-62` | 列表行用泛型直传 `RoundedRectangle`；`AnyView` 版本只留给非列表场景 |
| P1-29 | 启动路径上主线程同步解码大量缓存：`AppState.init` 读 `loadCachedAccount()` + `loadCachedLikedSongs()`（可能上千首）；`restoreLoginState` 里又重复读一次 account（`:166`，因 `:165` 有守卫属冗余） | `ClearToneApp.swift:122-123, 165-166` | `init` 保持为空，缓存读取统一到 `restoreLoginState()`；删 `:166` |
| P1-30 | `PersistenceStore.storageURL` 是**计算属性，每次访问都 `createDirectory`**（一次 mkdir 系统调用）；且所有方法同步无隔离 | `PersistenceStore.swift:12-24` | 改 `private let storageURL: URL = { ... }()`，建目录只做一次；写入改走 P0-2 的 `PersistenceWriter` |

---

## 四、P2 — 次要与重构（不阻塞，择机做）

| # | 问题 | 证据 | 改法 |
|---|---|---|---|
| P2-1 | `timePublisher` 是死代码（第 32 行注释描述的架构从未落地），误导后来者 | `PlayerController.swift:32-33` | 随 P0-4 一并处理，否则删掉 |
| P2-2 | `PlayerController.localProvider` 是从未使用的死对象 | `PlayerController.swift:45-46` | 删除或改 `LocalProvider.shared` |
| P2-3 | `AmbientBackgroundRenderer.pause()/resume()` 死代码 | `AmbientBackgroundRenderer.swift:66-72` | 随 P1-17 接入 |
| P2-4 | 对 `ScrollView` 使用了 `List` 专属修饰符（无效代码，`scrollContentBackground` 失效意味着背景可能不透明） | `MainWindow.swift:503-504` | 删除；需要透明背景就加 `.background(Color.clear)` |
| P2-5 | `MusicError` 缺 `Equatable`，且 `case unknown(String)` 丢弃底层 `Error`（无法做 `URLError` 判定），`localizedDescription` 随系统语言变化不利于测试断言 | `MusicError.swift:3`、`NeteaseProvider.swift:536` | 改 `case unknown(underlying:message:)`，加 `Equatable` 或 `isRetryable` |
| P2-6 | **错误信息原样透传到 UI 不经脱敏**：`MusicError.unknown(error.localizedDescription)` 与 `.apiError(message:)` 把服务端 message 直接给界面 | `NeteaseProvider.swift:536, 466, 516` | 在 `MusicError` 出口统一 `CTLog.sanitize`。同时扩展脱敏正则（当前只认 `key=value`，不认 JSON 的 `"MUSIC_U":"..."`，且漏 `MUSIC_A`/`__remember_me`） |
| P2-7 | 崩溃/强杀后 `tmp-*.caf` 成为永久孤儿，并因扩展名是 `.caf` 被写进正式索引 | `AudioCacheManager.swift:178-180, 131-137` | `refreshIndex()` 末尾清扫 `tmp-` 前缀文件；`tmp-` 提取为常量 |
| P2-8 | `trimIfNeeded` 可能删掉**正在播放**的缓存文件（它 mtime 最旧，APFS 上已开 fd 可继续读但有窗口期失败） | `AudioCacheManager.swift:140-161` | 淘汰时跳过 `currentCachedSongID` |
| P2-9 | 缓存任务与播放流**双倍带宽**（同一 URL 下载两遍），且无并发/限速控制，会与播放抢连接池 | `PlayerController.swift:175-182`、`AudioCacheManager.swift:170` | 改用 `AVAssetDownloadTask`（复用分片，省一半流量）；或至少限制缓存并发为 1 + `httpMaximumConnectionsPerHost = 2` |
| P2-10 | `SearchField` 本地文本与 `appState.searchQuery` 不双向同步，切走再切回输入框被清空 | `MainWindow.swift:204, 212-216` | `TextField(text: $appState.searchQuery)`，或 `onChange(currentPage)` 回填 |
| P2-11 | `MainWindow.swift` 906 行塞了 15 个 View + 1 个 Loader，同时含网络加载/缓存读写/导航/头像缓存四种关注点 | `MainWindow.swift` 全文 | 按现有 `Features/` 目录拆成 7~8 个文件 |
| P2-12 | `AvatarLoader` 与 `CoverLoader` 逻辑高度重复（都是 URLSession + NSCache + 下采样），`AvatarLoader` 还没走去重/磁盘缓存 | `MainWindow.swift:263-286`、`CoverImage.swift:68-145` | 合并为一个 loader，`AvatarView` 复用其缓存；删 `AvatarLoader` |
| P2-13 | 恢复队列时 `currentIndex` 只做上限夹取，下限未处理（`items` 为空时为 -1） | `PlayerController.swift:550` | 夹取到 `0...max(0, count-1)` |

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
