import SwiftUI
import AppKit

/// 菜单栏播放控制。
///
/// 这个视图被装进 `NSStatusItem` 的 `NSMenu`（见 `MenuBarController`），
/// 不是 SwiftUI 的 `MenuBarExtra` —— 后者无法在运行时隐藏，
/// 「关窗后缩到菜单栏」就实现不了。
///
/// 因此动作一律走显式回调，不用 `@Environment(\.openWindow)`：
/// 装在 `NSHostingView` 里时那个 environment 是空的，调用不会报错也不会有任何反应。
///
/// 菜单栏放不下一首完整的信息，所以只给「现在在放什么」+ 三个核心动作
/// （上一首 / 播放暂停 / 下一首）。音量、队列、音质留在主窗口或迷你播放器里。
struct MenuBarPlayerView: View {
    let onOpenMainWindow: () -> Void
    let onOpenMiniPlayer: () -> Void
    let onQuit: () -> Void

    @EnvironmentObject var player: PlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let song = player.currentSong {
                Text(song.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(song.artistNames)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if player.playbackState.isBuffering {
                    Text("缓冲中…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if player.isRateAdjusted {
                    Text("倍速 \(player.playbackRateLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("未在播放")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button(player.playbackState.isPlayIntentActive ? "暂停" : "播放") {
                player.togglePlayPause()
            }
            .disabled(player.currentSong == nil)

            Button("下一首") { player.next() }
                .disabled(!player.queue.hasNext)
            Button("上一首") { player.previous() }
                .disabled(!player.queue.hasPrevious)

            Divider()

            Button("打开主窗口", action: onOpenMainWindow)
            Button("迷你播放器", action: onOpenMiniPlayer)

            Divider()

            Button("退出澄音", action: onQuit)
        }
        .padding(.vertical, 6)
    }
}
