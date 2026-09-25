import SwiftUI

/// 迷你播放器
struct MiniPlayerView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: CTSpacing.sm) {
            // 封面与信息
            HStack(spacing: CTSpacing.md) {
                AsyncImage(url: player.currentSong?.coverURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
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

            // 进度条
            ProgressSlider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                maximum: max(player.duration, 1),
                buffered: player.bufferedTime
            )
            .frame(height: 3)

            // 控制
            HStack {
                Button(action: { player.previous() }) {
                    Image(systemName: "backward.fill")
                }
                .disabled(!player.queue.hasPrevious)

                Spacer()

                Button(action: { player.togglePlayPause() }) {
                    Image(systemName: player.playbackState.isPlaying ? "pause.fill" : "play.fill")
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
    }
}
