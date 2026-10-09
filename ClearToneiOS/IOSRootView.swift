import SwiftUI

struct IOSRootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerController
    @State private var showPlayer = false
    var body: some View {
        TabView {
            tab { IOSDiscoverView() }.tabItem { Label("发现", systemImage: "sparkles") }
            tab { IOSSearchView() }.tabItem { Label("搜索", systemImage: "magnifyingglass") }
            tab { IOSLibraryView() }.tabItem { Label("资料库", systemImage: "music.note.list") }
            tab { IOSSettingsView() }.tabItem { Label("设置", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showPlayer) { IOSNowPlayingView().presentationDragIndicator(.visible) }
        .sheet(isPresented: $appState.isLoginPresented) { IOSLoginView().presentationDragIndicator(.visible) }
        .alert("操作失败", isPresented: Binding(get: { appState.lastWriteError != nil }, set: { if !$0 { appState.clearWriteError() } })) {
            Button("好") { appState.clearWriteError() }
        } message: { Text(appState.lastWriteError ?? "") }
    }

    private func tab<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // **不要**给这里的 NavigationStack 加 `.id(appState.dataContextKey)`。
        //
        // 曾用它做「换号后重建导航栈」，但在 iOS 26.4 / 27.0 上，只要
        // dataContextKey 在某个 tab 首次显示之前变过（冷启动恢复登录态就会），
        // 之后再点那个 tab 会失败：要么没反应，要么落到「发现」，
        // 而其它 tab 正常 —— 实测「资料库点不开」就是它。
        // 账号快照的清理改由快照页自己负责（见 `IOSSongListView` 的 onChange）。
        NavigationStack { content() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.currentSong != nil {
                    IOSMiniPlayer { showPlayer = true }.padding(.horizontal, 12).padding(.bottom, 6)
                }
            }
    }
}

private struct IOSMiniPlayer: View {
    @EnvironmentObject private var player: PlayerController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var elapsed: Double = 0
    let open: () -> Void
    var body: some View {
        if let song = player.currentSong {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: open) {
                        HStack(spacing: 10) {
                            IOSCover(url: song.coverURL, size: 44, cornerRadius: 12)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(status(song)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle()).frame(minHeight: 48)
                    }.buttonStyle(.plain).accessibilityLabel("打开正在播放，\(song.title)，\(status(song))")
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.playbackState.isPlayIntentActive ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 44)
                    }.accessibilityLabel(player.playbackState.isPlayIntentActive ? "暂停" : "播放")
                    Button { player.next() } label: {
                        Image(systemName: "forward.end.fill").font(.title3).frame(width: 44, height: 44)
                    }.accessibilityLabel("下一首")
                }.padding(8)
                GeometryReader { proxy in
                    Capsule().fill(IOSTheme.accent).frame(width: proxy.size.width * progress)
                }.frame(height: 2).accessibilityHidden(true).padding(.horizontal, 16)
            }.padding(.bottom, 6)
                .background {
                    if reduceTransparency { RoundedRectangle(cornerRadius: 20).fill(IOSTheme.surface) }
                    else { RoundedRectangle(cornerRadius: 20).fill(.regularMaterial) }
                }
                .overlay { RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.06), lineWidth: 1) }
                .onAppear { elapsed = player.currentTime }
                .onReceive(player.timePublisher) { elapsed = $0 }
                .onChange(of: player.currentSong?.id) { _, _ in elapsed = player.currentTime }
        }
    }
    private var progress: CGFloat {
        guard player.duration.isFinite, player.duration > 0, elapsed.isFinite else { return 0 }
        return CGFloat(min(1, max(0, elapsed / player.duration)))
    }
    private func status(_ song: Song) -> String {
        if case .failed = player.playbackState { return "播放失败 · 点按查看" }
        if player.playbackState.isLoading { return "正在加载…" }
        if player.playbackState.isBuffering { return "正在缓冲…" }
        return song.artistNames
    }
}

struct IOSSongRow: View {
    let song: Song
    var play: () -> Void
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerController
    var body: some View {
        HStack {
            Button(action: play) {
                HStack(spacing: 12) {
                    IOSCover(url: song.coverURL)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title).foregroundStyle(.primary).lineLimit(2)
                        Text(song.artistNames).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if player.currentSong?.id == song.id, player.currentSong?.source == song.source { Image(systemName: player.playbackState.isPlayIntentActive ? "waveform" : "pause.fill").foregroundStyle(IOSTheme.accent).accessibilityLabel("当前歌曲") }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).frame(minHeight: 56).accessibilityLabel("播放，\(song.title)，\(song.artistNames)")
            Menu {
                Button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") { player.insertNext(song) }
                Button("加入队列", systemImage: "text.badge.plus") { player.appendToQueue(song) }
                if song.source == .netease {
                    Button(appState.isLiked(song.id) ? "取消喜欢" : "喜欢", systemImage: appState.isLiked(song.id) ? "heart.fill" : "heart") {
                        if appState.canPerformWrite { Task { _ = await appState.toggleLike(song) } }
                        else { appState.isLoginPresented = true }
                    }
                    // 限流冷却期间禁用并说明原因 —— 否则按钮看着可点，点下去毫无反应
                    .disabled(appState.isLikeWriteCoolingDown)
                    if appState.isLikeWriteCoolingDown {
                        Text(appState.likesWriteError ?? "操作过于频繁，约 \(appState.likeCooldownRemaining) 秒后可再试")
                    }
                    ForEach(song.artists) { artist in NavigationLink(artist.name) { IOSCollectionView(kind: .artist(artist.id)) } }
                    if let album = song.album { NavigationLink("专辑：\(album.name)") { IOSCollectionView(kind: .album(album.id)) } }
                    NavigationLink("歌曲评论") { IOSCommentsView(song: song) }
                    if appState.canPerformWrite {
                        Menu("添加到歌单") {
                            ForEach(appState.userPlaylists.filter { !$0.isSubscribed }) { playlist in
                                Button(playlist.name) { Task { _ = await appState.modifyPlaylist(playlist, songIDs: [song.id], add: true) } }
                            }
                        }
                    }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel("\(song.title)的更多操作")
        }
    }
}

struct IOSPlaylistRow: View {
    let playlist: Playlist
    var body: some View {
        NavigationLink { IOSCollectionView(kind: .playlist(playlist.id)) } label: {
            HStack(spacing: 12) {
                IOSCover(url: playlist.coverURL, size: 56)
                VStack(alignment: .leading, spacing: 5) {
                    Text(playlist.name).lineLimit(2)
                    Text(playlist.creatorName ?? "网易云音乐").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(.vertical, 3)
        }
    }
}

struct IOSFailure: View {
    let message: String
    var retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("暂时无法加载").font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("重试", action: retry).buttonStyle(.bordered)
        }.frame(maxWidth: .infinity).padding()
    }
}
