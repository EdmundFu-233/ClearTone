import SwiftUI

/// 我喜欢页
/// （原在 `App/MainWindow.swift`，按 P2-11 拆出）

struct LikedView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    /// 直接用 AppState 的缓存列表（收藏后即时同步）。
    /// 加载态与错误不归本页管：`AppState.loadLikedSongs` 失败只记日志，
    /// 并用磁盘缓存兜底渲染，所以这里不需要自建一套。
    private var songs: [Song] { appState.likedSongs }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CTPageHeader(title: "喜欢的音乐", subtitle: songs.isEmpty ? "把心动的旋律，留在身边。" : "\(songs.count) 首珍藏 · 随时重温", icon: "heart.fill")
                if !songs.isEmpty {
                    Button { player.play(songs: songs, startAt: 0) } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(CTSpacing.xl)

            if !appState.isLoggedIn {
                EmptyStateView(icon: "heart", title: "喜欢的音乐", message: "登录后查看喜欢的歌曲")
            } else if songs.isEmpty {
                EmptyStateView(icon: "heart", title: "喜欢的音乐", message: "还没有喜欢的歌曲")
            } else {
                List(songs) { song in
                    SongRowView(song: song, onPlay: {
                        player.play(songs: songs, startAt: songs.firstIndex(of: song) ?? 0)
                    })
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(CTColors.background(for: colorScheme))
        .task(id: appState.dataContextKey) { await load() }
    }

    private func load() async {
        guard appState.isLoggedIn else { return }
        await appState.loadLikedSongs()
    }
}
