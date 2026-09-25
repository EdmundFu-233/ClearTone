import SwiftUI

/// 底部常驻播放栏
///
/// 布局要点：右侧「状态槽」固定宽度，缓存/音质/缓存中/失败 四种状态共用一个槽位，
/// 任何状态出现或消失都不会改变右侧宽度，因此播放进度条区域始终保持同一宽度与位置。
struct PlayerBarView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var appState: AppState
    @ObservedObject private var audioCache = AudioCacheManager.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) var colorScheme

    /// 状态槽固定宽度（缓存 / 音质 / 缓存中 / 失败 共用）
    private let statusSlotWidth: CGFloat = 118
    /// 信息区宽度：与右侧区域大致等宽，使中间的控制按钮落在窗口正中
    private let infoWidth: CGFloat = 330

    var body: some View {
        HStack(spacing: CTSpacing.lg) {
            // 左侧：封面/歌名/歌手
            infoSection
                .frame(width: infoWidth, alignment: .leading)

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
            progressContent(time: 0)
                .frame(minWidth: 230, maxWidth: .infinity)
                .observingPlaybackTime(player) { currentTime in
                    progressContent(time: currentTime)
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
                .frame(width: 70)
                .accessibilityLabel("音量")
            }

            // 收藏
            if let song = player.currentSong, song.source == .netease {
                Button(action: { Task { await appState.toggleLike(song) } }) {
                    Image(systemName: appState.isLiked(song.id) ? "heart.fill" : "heart")
                        .foregroundStyle(appState.isLiked(song.id) ? CTColors.accent(for: colorScheme) : CTColors.textSecondary(for: colorScheme))
                }
                .buttonStyle(.plain)
                .disabled(!appState.isLoggedIn || appState.isDemoMode)
                .help(appState.isLiked(song.id) ? "取消收藏" : "收藏到喜欢的音乐")
                .accessibilityLabel(appState.isLiked(song.id) ? "取消收藏" : "收藏")
            }

            // 歌词
            Button(action: { appState.isNowPlayingExpanded = true }) {
                Image(systemName: "text.quote")
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            }
            .buttonStyle(.plain)
            .help(L10n.Common.lyrics)

            // 迷你播放器
            Button(action: { openWindow(id: "mini-player") }) {
                Image(systemName: "rectangle.on.rectangle")
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            }
            .buttonStyle(.plain)
            .help("迷你播放器")

            // 队列
            Button(action: { appState.showQueue.toggle() }) {
                Image(systemName: "list.bullet")
                    .foregroundStyle(appState.showQueue ? CTColors.accent(for: colorScheme) : CTColors.textSecondary(for: colorScheme))
            }
            .buttonStyle(.plain)
            .help(L10n.Common.queue)
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
        } else if let song = player.currentSong,
                  song.source == .netease,
                  let meta = audioCache.meta(for: song.id) {
            // 有缓存：显示缓存格式与码率（正在播缓存时高亮）
            let fromCache = player.isCurrentFromCache
            HStack(spacing: 4) {
                Image(systemName: fromCache ? "internaldrive.fill" : "internaldrive")
                Text("OPUS \(meta.bitrateKbps)k")
            }
            .font(CTTypography.caption)
            .foregroundStyle(fromCache ? CTColors.accent(for: colorScheme) : CTColors.textSecondary(for: colorScheme))
            .padding(.horizontal, CTSpacing.sm)
            .padding(.vertical, 2)
            .background(fromCache ? CTColors.accentSubtle(for: colorScheme) : CTColors.overlay(for: colorScheme))
            .cornerRadius(CTRadius.small)
            .help(fromCache
                  ? "正在播放本地缓存：\(meta.formatName) \(meta.bitrateKbps)kbps（优先于在线流）"
                  : "本地已有缓存：\(meta.formatName) \(meta.bitrateKbps)kbps，下次播放优先使用")
            .accessibilityLabel("\(fromCache ? "正在播放缓存" : "已缓存")，\(meta.formatName) \(meta.bitrateKbps) kbps")
        } else if let song = player.currentSong,
                  song.source == .netease,
                  audioCache.cachingSongIDs.contains(song.id) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle")
                Text("缓存中")
            }
            .font(CTTypography.caption)
            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            .help("正在缓存为 OPUS 96kbps…")
        } else if !player.isCurrentFromCache, let actual = player.actualQuality {
            // 无缓存：显示音质（含实际码率）
            Text(actual.bitrate.map { "\(actual.level.rawValue) \($0)k" } ?? actual.level.rawValue)
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                .padding(.horizontal, CTSpacing.sm)
                .padding(.vertical, 2)
                .background(CTColors.accentSubtle(for: colorScheme))
                .cornerRadius(CTRadius.small)
                .help("\(L10n.Player.requestedQuality): \(player.requestedQuality.rawValue)\n\(L10n.Player.actualQuality): \(actual.level.rawValue)")
        }
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
