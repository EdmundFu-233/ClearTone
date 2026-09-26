import SwiftUI

/// 底部迷你播放器（贴在标签栏之上）。
///
/// 与 macOS 的 `MiniPlayerView` 行为一致：显示封面/标题/播放控制，
/// 点击展开为全屏播放页。iOS 的 safeAreaInset 会自动避开 Home Indicator。
struct MiniPlayerBar: View {
    @EnvironmentObject private var player: PlayerController
    @Environment(\.colorScheme) private var colorScheme
    @State private var showNowPlaying = false

    var body: some View {
        if let song = player.currentSong {
            VStack(spacing: 0) {
                Divider()

                // 进度条：贴在播放器顶部
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(CTColors.accent(for: colorScheme))
                    .scaleEffect(x: 1, y: 0.5, anchor: .center)
                    .frame(height: 2)

                HStack(spacing: CTSpacing.md) {
                    CoverTile(url: song.coverURL, size: 40) {
                        AnyView(
                            RoundedRectangle(cornerRadius: CTRadius.small)
                                .fill(CTColors.overlay(for: colorScheme))
                                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                        )
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title)
                            .font(CTTypography.bodyMedium)
                            .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                            .lineLimit(1)
                        Text(song.artistNames)
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    // 缓存 / 缓冲 / 音质状态，只在需要时占位
                    statusSlot

                    Button { player.togglePlayPause() } label: {
                        Image(systemName: playIcon)
                            .font(.title3)
                            .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.playbackState.isPlaying ? "暂停" : "播放")

                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.body)
                            .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("下一首")
                }
                .padding(.horizontal, CTSpacing.lg)
                .padding(.vertical, CTSpacing.sm)
                .contentShape(Rectangle())
                .onTapGesture { showNowPlaying = true }
            }
            .background(CTColors.panel(for: colorScheme))
            .sheet(isPresented: $showNowPlaying) {
                NowPlayingSheet()
            }
        }
    }

    /// 固定宽度槽位：状态文字出现/消失时按钮不会位移
    private var statusSlot: some View {
        Group {
            if case .buffering = player.playbackState {
                Text("缓冲中")
            } else if player.isCurrentFromCache {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    .accessibilityLabel("已缓存")
            }
        }
        .font(CTTypography.caption)
        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
        .frame(width: 54, alignment: .trailing)
    }

    private var playIcon: String {
        if case .buffering = player.playbackState { return "hourglass" }
        return player.playbackState.isPlaying ? "pause.fill" : "play.fill"
    }

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.currentTime / player.duration))
    }
}

/// 全屏播放页
struct NowPlayingSheet: View {
    @EnvironmentObject private var player: PlayerController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: CTSpacing.xl) {
                Spacer()

                if let song = player.currentSong {
                    CoverTile(url: song.coverURL, size: 300) {
                        AnyView(
                            RoundedRectangle(cornerRadius: CTRadius.large)
                                .fill(CTColors.overlay(for: colorScheme))
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.largeTitle)
                                        .foregroundStyle(.secondary)
                                )
                        )
                    }
                    .shadow(radius: 16)

                    VStack(spacing: 4) {
                        Text(song.title)
                            .font(CTTypography.sectionTitle)
                            .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                            .multilineTextAlignment(.center)
                        Text(song.artistNames)
                            .font(CTTypography.body)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    }
                    .padding(.horizontal, CTSpacing.xl)
                }

                // 进度 + 时间
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.previewSeek(to: $0) }
                        ),
                        in: 0...max(1, player.duration),
                        onEditingChanged: { editing in
                            // 拖动中只 preview，松手才 commit —— 与 macOS 端
                            // PlayerBarView 的 seekToken 语义一致
                            if !editing { player.commitSeek(to: player.currentTime) }
                        }
                    )
                    .tint(CTColors.accent(for: colorScheme))

                    HStack {
                        Text(SongRow.format(player.currentTime))
                        Spacer()
                        Text("-\(SongRow.format(max(0, player.duration - player.currentTime)))")
                    }
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    .monospacedDigit()
                }
                .padding(.horizontal, CTSpacing.xl)

                // 播放控制
                HStack(spacing: 40) {
                    Button { player.previous() } label: {
                        Image(systemName: "backward.fill").font(.title)
                    }
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.playbackState.isPlaying
                              ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(CTColors.accent(for: colorScheme))
                    }
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.title)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))

                Spacer()
            }
            .padding(.vertical, CTSpacing.xl)
            .background(CTColors.background(for: colorScheme))
            .navigationTitle("正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
