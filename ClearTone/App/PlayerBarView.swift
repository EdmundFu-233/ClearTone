import SwiftUI

/// 底部常驻播放栏
///
/// 布局要点：右侧「状态槽」固定宽度，缓存/音质/缓存中/失败 四种状态共用一个槽位，
/// 任何状态出现或消失都不会改变右侧宽度，因此播放进度条区域始终保持同一宽度与位置。
struct PlayerBarView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var appState: AppState
    /// 缓存状态变化（正在写 / 写完）要即时反映到音源标签上，
    /// 而 PlayerController 不订阅 AudioCacheManager，所以由视图自己观察
    @ObservedObject private var audioCache = AudioCacheManager.shared
    @Environment(\.colorScheme) var colorScheme

    /// 状态槽固定宽度（缓存 / 音质 / 缓存中 / 失败 共用）
    /// 132 按最长的实际内容量的：「FLAC 1411k」+ 缓存图标 + 下拉箭头 + 内边距。
    /// 窄到放不下时 `ViewThatFits` 会退到紧凑文案，而不是把文字截断。
    private let statusSlotWidth: CGFloat = 132
    /// 信息区宽度：与右侧区域大致等宽，使中间的控制按钮落在窗口正中
    private let infoWidth: CGFloat = 330

    var body: some View {
        HStack(spacing: CTSpacing.lg) {
            // 左侧：封面/歌名/歌手。
            // 可压缩（歌名本身有 lineLimit(1)+省略号）：窗口窄时让它先让位，
            // 否则被挤掉的会是右侧的音源标签（文字被截成 "96k"，编码都丢了）
            infoSection
                .frame(minWidth: 190, maxWidth: infoWidth, alignment: .leading)
                .layoutPriority(0)

            // 中间：播放控制 + 进度条
            middleSection
                .frame(minWidth: 230, maxWidth: .infinity)

            // 右侧：状态槽 + 音量 + 功能按钮
            rightSection
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, CTSpacing.lg)
        .padding(.vertical, CTSpacing.sm)
        .frame(height: 88)
        .ctGlassSurface(radius: 22)
        .padding(.horizontal, CTSpacing.md)
        .padding(.bottom, CTSpacing.md)
        .padding(.top, CTSpacing.sm)
    }

    // MARK: - 信息区

    private var infoSection: some View {
        HStack(spacing: CTSpacing.md) {
            // 封面
            Button(action: { appState.isNowPlayingExpanded = true }) {
                CoverImage(url: player.currentSong?.coverURL, size: 56) {
                    RoundedRectangle(cornerRadius: CTRadius.small)
                        .fill(CTColors.overlay(for: colorScheme))
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        )
                }
                .frame(width: 56, height: 56)
                .cornerRadius(CTRadius.small)
            }
            .buttonStyle(.plain)
            .help("展开正在播放")

            // 歌名/歌手
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentSong?.title ?? "未在播放")
                    .font(CTTypography.bodyMedium)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    .lineLimit(1)

                Text(player.currentSong?.artistNames ?? "")
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 中间：播放控制 + 进度

    private var middleSection: some View {
        VStack(spacing: CTSpacing.xs) {
            // 控制按钮
            HStack(spacing: CTSpacing.lg) {
                // 播放模式
                Button(action: { cyclePlayMode() }) {
                    Image(systemName: playModeIcon)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                }
                .buttonStyle(.plain)
                .help(player.queue.mode.rawValue)

                // 上一首
                Button(action: { player.previous() }) {
                    Image(systemName: "backward.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(!player.queue.hasPrevious)
                .help(L10n.Common.previous)

                // 播放/暂停
                Button(action: { player.togglePlayPause() }) {
                    Image(systemName: player.playbackState.isPlayIntentActive ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(CTColors.accent(for: colorScheme))
                }
                .buttonStyle(.plain)
                .disabled(player.currentSong == nil)
                .accessibilityLabel(player.playbackState.isPlayIntentActive ? "暂停" : "播放")
                .help(player.playbackState.isPlayIntentActive ? L10n.Common.pause : L10n.Common.play)

                // 缓冲中：给一个明确提示，否则网络抖动时界面看起来像卡死
                if player.playbackState.isBuffering {
                    Text("缓冲中…")
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        .fixedSize()
                        .transition(.opacity)
                }

                // 下一首
                Button(action: { player.next() }) {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(!player.queue.hasNext)
                .help(L10n.Common.next)

                // 占位（平衡布局）
                Image(systemName: "list.bullet")
                    .opacity(0)
            }

            // 进度条。用 observingPlaybackTime 局部订阅：播放进度 2Hz 变化
            // 不再牵动整棵视图树，只有这一小段重算。
            // 拖动中只更新 UI 时间（previewSeek），抬手才提交一次精确 seek（commitSeek）——
            // 原先每帧都提交零容差 seek，而 Task.cancel 撤不回已提交给 AVFoundation 的请求。
            //
            // 宽度约束必须**写在闭包里面**：`observingPlaybackTime` 会丢弃接收者
            // `self`，写在它前面的 `.frame(minWidth:maxWidth:)` 会被静默丢掉。
            observingPlaybackTime(player) { currentTime in
                progressContent(time: currentTime)
                    .frame(minWidth: 230, maxWidth: .infinity)
            }
            .onChange(of: progressIsDragging) { _, dragging in
                // 抬手：把预览位置真正提交给播放器
                if !dragging { player.commitSeek(to: player.currentTime) }
            }
        }
    }

    /// 进度条是否正在被拖动
    @State private var progressIsDragging = false

    @ViewBuilder
    private func progressContent(time: TimeInterval) -> some View {
        HStack(spacing: CTSpacing.sm) {
            Text(formatTime(time))
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                .monospacedDigit()

            ProgressSlider(
                value: Binding(
                    get: { time },
                    set: { newValue in
                        if progressIsDragging {
                            player.previewSeek(to: newValue)
                        } else {
                            player.commitSeek(to: newValue)
                        }
                    }
                ),
                maximum: max(player.duration, 1),
                buffered: player.bufferedTime,
                onEditingChanged: { progressIsDragging = $0 }
            )
            .frame(height: 22)
            .disabled(player.currentSong == nil)

            Text(formatTime(player.duration))
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                .monospacedDigit()
        }
    }

    // MARK: - 右侧

    private var rightSection: some View {
        HStack(spacing: CTSpacing.md) {
            // 固定宽度状态槽：任何状态都不改变右侧整体宽度
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                statusChip
            }
            .frame(width: statusSlotWidth, height: 20, alignment: .trailing)

            // 音量
            HStack(spacing: CTSpacing.xs) {
                Button(action: { player.isMuted.toggle() }) {
                    Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isMuted ? "取消静音" : "静音")

                Slider(value: Binding(
                    get: { Double(player.volume) },
                    set: { player.volume = Float($0) }
                ), in: 0...1)
                // 音量是这一排里最可牺牲的：窗口变窄时它先收缩，
                // 音源标签的「编码 + 码率」必须完整显示
                .frame(minWidth: 34, maxWidth: 70)
                .accessibilityLabel("音量")
            }
            .layoutPriority(-1)

            // 收藏
            if let song = player.currentSong, song.source == .netease {
                Button(action: { Task { await appState.toggleLike(song) } }) {
                    Image(systemName: appState.isLiked(song.id) ? "heart.fill" : "heart")
                        .foregroundStyle(appState.isLiked(song.id) ? CTColors.accent(for: colorScheme) : CTColors.textSecondary(for: colorScheme))
                }
                .buttonStyle(.plain)
                .disabled(!appState.isLoggedIn)
                .help(appState.isLiked(song.id) ? "取消收藏" : "收藏到喜欢的音乐")
                .accessibilityLabel(appState.isLiked(song.id) ? "取消收藏" : "收藏")
                .fixedSize()
            }

            // 歌词
            Button(action: { appState.isNowPlayingExpanded = true }) {
                Image(systemName: "text.quote")
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            }
            .buttonStyle(.plain)
            .help(L10n.Common.lyrics)
            .fixedSize()

            // 倍速 + 睡眠定时器
            PlaybackUtilitiesMenu()

            // 迷你播放器
            Button(action: { AppWindowController.openMiniPlayer() }) {
                Image(systemName: "rectangle.on.rectangle")
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            }
            .buttonStyle(.plain)
            .help("迷你播放器")
            .fixedSize()

            // 队列
            Button(action: { appState.showQueue.toggle() }) {
                Image(systemName: "list.bullet")
                    .foregroundStyle(appState.showQueue ? CTColors.accent(for: colorScheme) : CTColors.textSecondary(for: colorScheme))
            }
            .buttonStyle(.plain)
            .help(L10n.Common.queue)
            .fixedSize()
        }
    }

    // MARK: - 状态槽内容（同时只显示一个状态）

    @ViewBuilder
    private var statusChip: some View {
        if case .failed(_, let reason) = player.playbackState {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help("播放失败：\(reason)\n点击播放按钮重试")
                .accessibilityLabel("播放失败")
        } else if let info = player.playingSourceInfo, let song = player.currentSong {
            // 网易云歌曲时整块变成菜单：点这里给「这一首」点名音质（走网易源、跳过缓存）
            if song.source == .netease {
                SongQualityMenu(
                    songID: song.id,
                    help: info.detail + "\n\n点击为这首歌指定音质"
                ) { sourceChip(info: info, song: song) }
            } else {
                sourceChip(info: info, song: song)
                    .help(info.detail)
            }
        }
    }

    /// 音源标签本体（不含菜单外壳）。
    ///
    /// 主信息 = 此刻真正出声的格式/码率；缓存只是旁注。后台缓存是「一开始播就写」，
    /// 若让缓存状态顶掉码率，一首第一次听的歌从头到尾显示的都是缓存状态，
    /// 和耳朵听到的 320k 对不上。
    ///
    /// 刻意写成分开的两个方法而不是在 @ViewBuilder 里定义局部闭包：
    /// 那个写法在 Release（-O）下会触发 Swift 编译器 CopyPropagation 断言崩溃。
    private func sourceChip(info: PlayingSourceInfo, song: Song) -> some View {
        // 完整文案放不下时退到紧凑形态（"无损 1411k" → "1411k"），
        // 而不是把文字截成 "OP…"
        ViewThatFits(in: .horizontal) {
            chipBody(info: info, song: song, text: info.text)
            chipBody(info: info, song: song, text: info.shortText)
        }
    }

    private func chipBody(info: PlayingSourceInfo, song: Song, text: String) -> some View {
        HStack(spacing: 4) {
            if info.isFromCache {
                Image(systemName: "internaldrive.fill")
            }
            Text(text)
                .lineLimit(1)
            if !info.isFromCache {
                // 有缓存 / 正在缓存：用弱化的小图标提示，不抢主信息
                switch info.cache {
                case .cached: Image(systemName: "internaldrive")
                case .caching: Image(systemName: "arrow.down.circle")
                case .none: EmptyView()
                }
            }
            if song.source == .netease {
                // 菜单的可点提示。放在标签里而不是依赖 Menu 自带的箭头：
                // 那个箭头带一圈 bezel，在固定宽度的状态槽里会把文字挤没
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
        }
        .font(CTTypography.caption)
        .foregroundStyle(info.isFromCache || player.currentSongUsesOverride
                         ? CTColors.accent(for: colorScheme) : CTColors.textSecondary(for: colorScheme))
        .padding(.horizontal, CTSpacing.sm)
        .padding(.vertical, 2)
        .background(info.isFromCache ? CTColors.accentSubtle(for: colorScheme) : CTColors.overlay(for: colorScheme))
        .cornerRadius(CTRadius.small)
        .accessibilityLabel("\(info.isFromCache ? "正在播放缓存" : "正在播放")：\(text)")
    }

    private var playModeIcon: String {
        switch player.queue.mode {
        case .sequential: return "arrow.right"
        case .loopAll: return "repeat"
        case .loopOne: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }

    private func cyclePlayMode() {
        let modes = PlayMode.allCases
        guard let currentIndex = modes.firstIndex(of: player.queue.mode) else { return }
        let nextIndex = (currentIndex + 1) % modes.count
        player.setPlayMode(modes[nextIndex])
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// 原生进度控件提供键盘和辅助功能操作，缓冲信息通过帮助文本展示。
struct ProgressSlider: View {
    @Binding var value: TimeInterval
    var maximum: TimeInterval
    var buffered: TimeInterval
    /// 拖动开始/结束回调。用于区分"拖动中只更新 UI"与"抬手才提交 seek"。
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Slider(value: $value, in: 0...max(maximum, 1), onEditingChanged: onEditingChanged)
            .tint(CTColors.accent(for: colorScheme))
            .help("已缓冲 \(Int(max(0, buffered))) 秒")
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(Int(value)) 秒，共 \(Int(maximum)) 秒")
    }
}
