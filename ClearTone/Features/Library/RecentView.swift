import SwiftUI

/// 最近播放页
/// （原在 `App/MainWindow.swift`，按 P2-11 拆出）

struct RecentView: View {
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CTPageHeader(
                    title: L10n.Sidebar.recent,
                    subtitle: player.recentlyPlayed.isEmpty ? "听过的歌会出现在这里。" : "最近 \(player.recentlyPlayed.count) 首",
                    icon: "clock"
                )
                if !player.recentlyPlayed.isEmpty {
                    Button { player.play(songs: player.recentlyPlayed, startAt: 0) } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(CTSpacing.xl)

            if player.recentlyPlayed.isEmpty {
                EmptyStateView(icon: "clock", title: "最近播放", message: "暂无播放记录")
            } else {
                List(player.recentlyPlayed) { song in
                    SongRowView(song: song, onPlay: {
                        player.play(songs: player.recentlyPlayed, startAt: player.recentlyPlayed.firstIndex(of: song) ?? 0)
                    })
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(CTColors.background(for: colorScheme))
    }
}
