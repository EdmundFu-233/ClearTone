import SwiftUI

/// 迷你播放器
struct MiniPlayerView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.colorScheme) var colorScheme
    /// 进度条是否正在被拖动
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: CTSpacing.sm) {
            // 封面与信息
            HStack(spacing: CTSpacing.md) {
                CoverImage(url: player.currentSong?.coverURL, size: 48) {
                    RoundedRectangle(cornerRadius: CTRadius.small)
                        .fill(CTColors.overlay(for: colorScheme))
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                }
                .frame(width: 48, height: 48)
                .cornerRadius(CTRadius.small)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentSong?.title ?? "未在播放")
                        .font(CTTypography.bodyMedium)
                        .lineLimit(1)
                    Text(player.currentSong?.artistNames ?? "")
                        .font(CTTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            // 进度条。局部订阅播放进度，拖动中只预览、抬手才提交。
            ProgressSlider(
                value: Binding(
                    get: { player.currentTime },
                    set: { newValue in
                        isDragging ? player.previewSeek(to: newValue) : player.commitSeek(to: newValue)
                    }
                ),
                maximum: max(player.duration, 1),
                buffered: player.bufferedTime,
                onEditingChanged: { isDragging = $0 }
            )
            .frame(height: 3)
            .observingPlaybackTime(player) { currentTime in
                ProgressSlider(
                    value: Binding(
                        get: { currentTime },
                        set: { newValue in
                            isDragging ? player.previewSeek(to: newValue) : player.commitSeek(to: newValue)
                        }
                    ),
                    maximum: max(player.duration, 1),
                    buffered: player.bufferedTime,
                    onEditingChanged: { isDragging = $0 }
                )
                .frame(height: 3)
            }
            .onChange(of: isDragging) { _, dragging in
                if !dragging { player.commitSeek(to: player.currentTime) }
            }

            // 控制
            HStack {
                Button(action: { player.previous() }) {
                    Image(systemName: "backward.fill")
                }
                .disabled(!player.queue.hasPrevious)

                Spacer()

                Button(action: { player.togglePlayPause() }) {
                    Image(systemName: player.playbackState.isPlayIntentActive ? "pause.fill" : "play.fill")
                        .font(.title2)
                }

                Spacer()

                Button(action: { player.next() }) {
                    Image(systemName: "forward.fill")
                }
                .disabled(!player.queue.hasNext)
            }
            .padding(.horizontal, CTSpacing.xl)
        }
        .padding(CTSpacing.md)
        .frame(width: 300)
        .background(CTColors.panel(for: colorScheme))
        // 置顶由 `MiniPlayerWindowController` 直接设 `NSWindow.level`。
        // 这里不再用 `floatingWindow`：它靠一个 `NSViewRepresentable` 在
        // `DispatchQueue.main.async` 里读 `view.window`，那个时机窗口通常还没建好，
        // 读到 nil，置顶静默失效。
    }
}
