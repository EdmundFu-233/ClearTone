# iOS 音量衰减修复

2026-09-30（America/Toronto）。

原因：共享 PlayerController 原来的应用内默认音量为 0.8，且从 queue.json 恢复旧音量/静音。iOS 页面使用 MPVolumeView 调节系统音量；AVPlayer.volume 是相对于系统音量的额外比例，导致系统音量之上再衰减。参见 [Apple AVPlayer.volume 文档](https://developer.apple.com/documentation/avfoundation/avplayer/volume)。

修复：新 PlaybackVolumePolicy 将 iOS 的内部输出设为 1.0、非静音，由系统媒体音量控制实际响度。策略同时用于默认值、旧快照恢复、AVPlayer 初次创建与切歌复用、运行时音量变化和新快照保存。macOS 的应用内音量、静音及既有用户值保持原语义。没有加增益、音效或响度归一化，也没有修改手机系统音量。

验证：

- 新增 4 项回归测试覆盖 iOS 旧低音量/静音、macOS 既有设置和当前平台默认值。
- ./scripts/run-tests.sh：457 项离线测试，0 失败、0 跳过，持久化隔离。
- 临时独立 iOS 验收壳以旧快照 volume=0.2 / mute=true 启动，使用本地静音 WAV；读取实际 AVPlayer 验证首次创建、运行时旧音量写入、切歌复用与快照保存均为 volume=1.0 / mute=false。运行日志：VOLUME_PROBE_PASS: AVPlayer.volume=1.0, isMuted=false, persistedVolume=1.0。验收壳已卸载，不进入生产 target。
- 最终 iPhone Debug 签名构建和 codesign --verify --deep --strict 通过。构建日志：build/iOS/build-device-volume-fix.log。
- iPhone 17 已覆盖安装 0.1.0（构建号 3），App ID com.cleartone.app.ios；启动成功，并确认进程仍在运行，保留原应用数据。

以上证明消除了播放器内部衰减；实际听感仍应以同一首歌、相同系统音量和输出设备试听确认。未进行麦克风录音或真机响度测量。
