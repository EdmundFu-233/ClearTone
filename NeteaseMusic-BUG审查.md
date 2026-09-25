# NeteaseMusic / ClearTone BUG 审查报告

审查日期：2026-09-25。范围：桌面 Project/NeteaseMusic 当前文件，包括 Swift 应用、辅助进程管理、内置 Node 接入与安装脚本。没有修改项目源码。该目录不是 Git 仓库，无法提供提交号或差异基线。

## 结论

记录 12 项有明确代码依据的缺陷：P1 3 项、P2 9 项。P1 表示崩溃、失控重试或自动恢复失效，P2 表示用户功能错误。三个队列行为已用原始源码独立执行确认；其余为静态调用链结论，未冒充真实账号或完整 GUI 验证。

## 1. [P1] 列表循环时清空队列会崩溃

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Playback/PlayQueue.swift:208`

触发与影响：播放任意歌曲，切换列表循环，然后清空队列，等待当前歌曲结束。clearQueue() 只清空数组，没有停止 AVPlayer；结束回调进入 handleEnded()，对 items.count == 0 取余。

证据：独立编译原始模型与队列代码，调用 clear() → handleEnded()，进程以信号 5 退出，报 Division by zero in remainder operation。

修复方向：对空队列提前返回，并明确清空队列时播放器的停止行为。

## 2. [P1] 连续失败三次停止的保护永远无法累计

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Playback/PlayerController.swift:82`

触发与影响：每次 play(song:) 都将 consecutiveFailures 清零；失败后 next() 又调用 play(song:)。循环队列中所有歌曲不可用时，会一直重试；单曲循环也会重复请求同一首失败歌曲。

证据：静态调用链：play → loadAndPlay → handlePlayError → next → play。

修复方向：仅在真正播放成功或用户显式发起新的播放操作时重置计数。

## 3. [P1] 健康检查触发的自动重启会取消自身

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Core/Networking/HelperProcessManager.swift:220`

触发与影响：辅助进程仍存活但健康检查失败时，healthCheckTask 调用 restart()；restart 调用 stop()，后者取消 healthCheckTask。随后的 throwing Task.sleep 抛出取消异常，start() 不会执行，错误被 try? 吞掉，服务留在 stopped。后续业务请求可能再启动它，但自动恢复本身失败。

证据：静态调用链：220 → 153–156 → 138–149。

修复方向：把监控任务取消与重启动作分离，确保重启在未取消任务中执行。

## 4. [P2] 旧歌曲的失败定时任务会跳过用户刚选的新歌曲

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Playback/PlayerController.swift:297`

触发与影响：A 失败后安排 1.5 秒延迟；用户在此期间手动播放 B，旧任务仍执行 next()，把 B 切到 C。任务未保存 generation，也没有可取消句柄。

证据：静态异步调用链确认；loadAndPlay 的 generation 校验没有覆盖该延迟任务。

修复方向：记录失败歌曲的 generation，切歌时取消任务，执行前验证仍为该次失败。

## 5. [P2] 拖动队列后当前歌曲指针变成另一首

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Playback/PlayQueue.swift:131`

触发与影响：队列 A/B/C 正在播放 A，把 A 拖到末尾。move 先重排，再按旧索引读取 currentItem，得到 B，无法保留 A 的身份，导致高亮和后续导航错误。

证据：原始队列代码独立运行：MOVE before=A after=B order=["B", "C", "A"]。

修复方向：重排前保存当前 QueueItem.id，重排后按该 ID 恢复索引。

## 6. [P2] 删除正在播放的条目会跳过它后面的歌曲

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Playback/PlayerController.swift:257`

触发与影响：A/B/C 正在播放 A，删除 A 后队列指针已经指向 B，但音频仍是 A。A 结束后 handleEnded 再递增索引，直接播放 C，跳过 B。

证据：原始队列代码独立运行：删除 A 后 handleEnded 返回 C；控制器代码确认删除时未同步播放器。

修复方向：删除当前条目时同步切换音频，或保留明确的待播放位置，避免结束回调再次推进。

## 7. [P2] 重启后点击恢复播放只改变界面，不会出声

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Playback/PlayerController.swift:196`

触发与影响：已有持久化队列时，初始化把状态设为 paused，却没有创建 AVPlayer。点击播放只执行 player?.play()，player 为 nil，随后界面仍切为 playing。resumeFromPersistence 在项目内没有调用点，且内部也未 seek 到保存时间。

证据：全项目调用点检索与初始化、resume 路径核对。

修复方向：首次恢复时加载音频、等待可播放并恢复进度，再按用户意图播放。

## 8. [P2] 正常播放和退出不会保存最新队列及进度

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Playback/PlayerController.swift:306`

触发与影响：persistState 只在设置播放模式、追加/插入/删除/清空队列时调用。搜索结果播放、下一首、暂停、seek、音量调整和退出均不保存，重启后可能没有队列或恢复旧歌曲、旧进度。

证据：核对全部 persistState/saveQueue 调用点及 applicationWillTerminate。

修复方向：在队列替换、切歌和退出等边界保存，进度采用适当节流。

## 9. [P2] 音质选择没有传递给实际播放请求

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Features/Settings/SettingsView.swift:33`

触发与影响：设置页修改 AppSettings.preferredQuality，但播放器使用独立的 requestedQuality；两者没有同步路径，后者仅由默认值或旧队列文件赋值。因此选择无损或 Hi-Res 后，请求仍使用原来的音质。

证据：全项目 preferredQuality/requestedQuality 引用检索。

修复方向：采用统一音质状态，并将修改同步到之后的 fetchPlayableURL 请求。

## 10. [P2] 旧搜索分页结果会混入新的搜索结果

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Features/Search/SearchView.swift:102`

触发与影响：搜索 A 并触发下一页，在该请求返回前搜索 B。loadMore 创建的 Task 不受 searchTask 取消管理，也不验证查询标识，A 返回后会把歌曲追加到 B 的结果；分页期间还没有设置加载锁，重复触发可以并发推进页码。

证据：核对 performSearch 与 loadMore 两条异步路径。

修复方向：为分页保存并校验查询代次，取消旧分页，并单独锁定分页加载。

## 11. [P2] 每次打开歌词窗口都会增加一个永久运行的定时器

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Features/NowPlaying/NowPlayingView.swift:207`

触发与影响：onAppear 调用 startTimeObserver，创建 0.1 秒重复 Timer；没有保存句柄或在消失时 invalidate。反复打开关闭正在播放窗口会不断累积定时器，闭包还持续持有播放器和歌词状态。

证据：核对 startTimeObserver、onAppear 和完整视图生命周期；未进行长时间性能测量。

修复方向：保存并在 onDisappear 释放 Timer，或用随视图生命周期取消的订阅。

## 12. [P2] 快速切歌会显示上一首的歌词

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Features/NowPlaying/NowPlayingView.swift:189`

触发与影响：A 的歌词请求未完成时切到 B；两个 Task 并行，若 A 最后返回会覆盖 B 的歌词，旧请求失败也会清空 B 的已加载歌词。没有取消句柄或歌曲 ID 校验。

证据：核对 loadLyrics 的创建与写回路径。

修复方向：切歌取消旧请求，写回前核对歌曲 ID 或 generation。

## 验证与限制

- 已运行独立 Swift 探针，使用项目原始 MusicModels.swift 和 PlayQueue.swift，仅额外导入 SwiftUI 以运行队列扩展；验证了空队列取余崩溃、重排指针错误、删除当前项后的跳歌。
- 已尝试 xcodebuild test，构建在 CompileMetalFile 阶段失败：本机缺少 Metal Toolchain。现有 XCTest 未执行，不能声称通过；这属于环境阻碍，没有计入代码 BUG。
- 未登录真实账号、未发起网易云账户写操作，未运行联网集成测试。
- 此外，MyMusicView、LikedView、RecentView、PlaylistDetailView 仍为硬编码占位视图，推荐歌单卡片未接导航，喜欢按钮的 action 为空。它们属于明显未完成功能，未混入以上 12 项逻辑缺陷。
- customAPIServer 与 resumePlaybackOnLaunch 也只有设置存取，未发现业务消费路径。安装脚本只生成独立 ct_health.js，未复现当前内置 app.js/server.js 中的 ClearTone 补丁；全新安装的可复现性需要进一步验证。
