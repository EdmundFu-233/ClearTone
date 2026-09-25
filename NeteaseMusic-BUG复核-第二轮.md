# NeteaseMusic 第二轮复核

日期：2026-09-25。复核当前桌面项目文件；未修改项目源码。

## 结论

上轮 12 项均有对应修改，但仍发现 5 项 P2 问题，主要集中在停止/切歌/恢复期间的异步状态和搜索重置。不能将当前版本判为全部修复完成。

## 仍需修复

### 1. [P2] 停止播放没有废弃在途请求

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Playback/PlayerController.swift:491`

触发与影响：开始加载 A，在 fetchPlayableURL 完成前清空队列或删除最后一项。stopPlayback 没有递增 currentGeneration，也没有取消 loadAndPlay 任务。旧请求返回后仍通过 128/133 行校验：失败会把空播放器从 idle 改成 failed；成功则会重新创建已被清理的 AVPlayer。

证据：已用原始 PlayerController、PlayQueue、模型源码执行定向探针。仅 Provider、持久化和日志换成隔离桩，不联网、不写真实用户状态。结果：immediately after clear: idle；after outstanding request completes: failed(songID: "A", ...); queue count=0。

修复建议：停止时递增播放代次，取消并持有加载任务；所有回调在写状态前校验代次。

### 2. [P2] 切歌后旧播放器的时间仍写入新歌曲并被持久化

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Playback/PlayerController.swift:200`

触发与影响：A 播到 120 秒后选择 B，B 的 URL 请求缓慢。beginPlay 已将 currentSong/队列切到 B，但要等 B 的 URL 返回才在 startPlayback 中 cleanupPlayer。因此 A 仍播放，且周期时间观察者没有 generation 校验，继续把 A 的时间写进 B 的 currentTime。持续超过 5 秒会由新加的节流保存落盘；期间暂停/退出也会把错误进度保存为 B 的进度。

证据：静态完整调用链：beginPlay 96–110、loadAndPlay 125–131、startPlayback 138–139、时间观察者 200–205。本次未进行真实音频时序测量。

修复建议：在开始切换时停止旧播放器/旧观察者，时间回调同时校验 generation；只保存当前歌曲对应的有效时钟。

### 3. [P2] 恢复 seek 完成后可能覆盖用户暂停并重新出声

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Playback/PlayerController.swift:219`

触发与影响：恢复已保存进度或切换音质会异步 seek；若在 seek 完成前通过系统媒体控制调用 pause，pause 只修改 playbackState，没有把 pendingAutoplay 设为 false。seek 完成回调仅校验 generation，仍按旧 pendingAutoplay=true 调用 play，覆盖用户暂停。

证据：静态调用链：startAudio 213–228；pause 240–248。尚未用真实 AVPlayer 复现 seek 时序。

修复建议：暂停/恢复需要同步用户播放意图；seek 完成时采用最新意图，同时正确处理 seek 的完成结果。

### 4. [P2] 编辑但未提交新关键词仍会混入另一搜索的分页

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Features/Search/SearchView.swift:114`

触发与影响：先搜索 A 并保留结果，将输入框改成 B 但不按回车，滚动 A 到底部。loadMore 读取当前输入框 B，而 searchGeneration 仍是 A 的代次，于是请求 B 的第 2 页并追加到 A。本轮修复仅覆盖了 performSearch 被调用的情形。

证据：静态数据流确认：TextField 只在 onSubmit 发起搜索；loadMore 使用 searchText 而非已提交查询。

修复建议：保存 activeQuery/activeType/activeProvider，后续分页始终读取该结果集对应的已提交参数；不要读取输入中的草稿。

### 5. [P2] 清空搜索框后旧请求会重新填回结果

位置：`/Users/edmundfu/Desktop/Project/NeteaseMusic/ClearTone/Features/Search/SearchView.swift:36`

触发与影响：发起搜索或分页，在请求返回前点击输入框右侧叉号。按钮只清空 searchText/result，没有增加 searchGeneration、取消任务或重置 isLoading；旧请求返回仍通过代次校验，显示已经清掉的搜索结果。

证据：静态确认 performSearch/loadMore 的写回条件与清空按钮行为。

修复建议：建立统一 resetSearch：递增代次、取消两类任务，并重置结果、页码、加载和错误状态。

## 上轮 12 项逐项核对

| 原编号 | 问题 | 本轮结论 |
|---|---|---|
| 1 | 空队列取余崩溃 | 已补空队列保护，独立回归测试通过；停止时另有本轮第 1 项异步漏洞 |
| 2 | 连续失败计数重置 | 自动失败切换改用 beginPlay，原调用链问题已修正；静态确认 |
| 3 | 健康重启自取消 | 已用独立 restartTask 分离，原路径已修正；未做真实子进程故障注入 |
| 4 | 旧失败任务跳新歌 | 已增加 generation 校验，用户切歌场景已修正；停止场景见本轮第 1 项 |
| 5 | 重排当前指针 | 回归测试通过，按重排前稳定 ID 定位 |
| 6 | 删除当前项跳歌 | 控制器现在主动切换到新当前项，原调用链已修正；静态确认 |
| 7 | 持久化恢复不出声 | 已增加重建与 seek 路径；恢复期间的暂停边界见第 3 项 |
| 8 | 播放进度未保存 | 已接入切歌、暂停、seek、退出与节流保存；旧时钟污染见第 2 项 |
| 9 | 音质设置未接入 | 设置页 onChange 已调用播放器统一音质入口；静态确认 |
| 10 | 旧搜索分页混入 | 新提交查询已有代次隔离；编辑及清空边界仍有第 4、5 项 |
| 11 | 歌词 Timer 泄漏 | 已改为 onReceive 管理订阅生命周期；静态确认，未做长时间内存测量 |
| 12 | 旧歌词响应覆盖 | 已取消旧请求并校验歌曲 ID；静态确认 |

## 验证结果与范围

- 从项目当前源码独立编译并运行现有 PlayQueueTests（11 项）与 LRCParserTests（7 项），共 18 项、0 失败。入口使用 XCTestSuite，额外导入 SwiftUI，不改变测试方法与业务源码。
- 隔离播放器探针确认清空后旧错误响应仍写回；并未把该探针当作真实联网/音频端到端测试。
- 再次运行完整 xcodebuild test，仍在 Metal 编译阶段被缺少 Metal Toolchain 阻断；完整应用构建与测试未通过验证。
- 本轮重点为上次报告及修复引入的状态边界；未登录真实账号，未核验占位页面是否已完成功能。
