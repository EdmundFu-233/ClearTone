import SwiftUI

/// 专辑详情页。
///
/// 接的是 `MusicProvider.fetchAlbumDetail` —— 这个方法早就实现了，
/// 但此前**没有任何 UI 调用它**，所以搜索结果里的专辑点进去是死的。
struct AlbumDetailView: View {
    let albumID: String
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    @State private var detail: PlaylistDetail?
    @State private var similarSongs: [Song] = []
    @State private var isLoading = false
    @State private var isLoadingSimilar = false
    @State private var errorMessage: String?
    @State private var isSubscribed: Bool?
    @State private var loadToken = UUID()

    private let provider = NeteaseProvider.shared

    private var tracks: [Song] { detail?.tracks ?? [] }
    private var albumName: String { detail?.playlist.name ?? "专辑" }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ErrorView(message: error) { Task { await load() } }
            } else if detail == nil {
                EmptyStateView(icon: "square.stack", title: "专辑", message: "专辑不存在或已下架")
            } else {
                header
                Divider()
                trackList
            }
        }
        .background(CTColors.background(for: colorScheme))
        .task(id: "\(albumID)-\(appState.dataContextKey)") { await load() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: CTSpacing.lg) {
            CoverImage(url: detail?.playlist.coverURL, size: 180) {
                RoundedRectangle(cornerRadius: CTRadius.medium)
                    .fill(CTColors.overlay(for: colorScheme))
                    .overlay(Image(systemName: "square.stack").font(.largeTitle).foregroundStyle(.secondary))
            }
            .frame(width: 180, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: CTRadius.medium))

            VStack(alignment: .leading, spacing: CTSpacing.sm) {
                Text(albumName)
                    .font(CTTypography.pageTitle)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                if let artist = detail?.playlist.creatorName {
                    // 以前这里是 `Button(artist) { /* 歌手 id 未知时不跳，避免死链 */ }`
                    // —— 一个能聚焦、能点、什么都不做的空按钮。
                    // 现在 `PlaylistDetail.artistID` 带回了 id（见 fetchAlbumDetail），
                    // 真的能跳；拿不到 id 时退回纯文本，不给用户一个骗人的按钮。
                    if let artistID = detail?.artistID {
                        Button(artist) { appState.openArtist(artistID) }
                            .buttonStyle(.plain)
                            .font(CTTypography.body)
                            .foregroundStyle(CTColors.accent(for: colorScheme))
                            .help("查看歌手：\(artist)")
                    } else {
                        Text(artist)
                            .font(CTTypography.body)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    }
                }
                Text("\(tracks.count) 首歌曲")
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))

                HStack(spacing: CTSpacing.md) {
                    Button {
                        player.play(songs: tracks, startAt: 0)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(tracks.isEmpty)

                    Button {
                        // 插到当前歌曲之后播放（不是「替换队列从头播」——那是左边那颗）。
                        // 原实现误调 `play(songs:startAt:)`，与「播放全部」完全等价，
                        // 于是页面上出现两个一模一样的按钮，而图标宣称的「下一首播放」
                        // 根本不存在。
                        player.insertNext(tracks)
                    } label: {
                        Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .buttonStyle(.bordered)
                    .disabled(tracks.isEmpty)

                    SubscribeButton(
                        target: .album(albumID),
                        title: "收藏专辑",
                        isSubscribed: isSubscribed
                    ) { newValue in
                        await toggleSubscribe(newValue)
                    }
                }
            }
            Spacer()
        }
        .padding(CTSpacing.xl)
    }

    // MARK: - 曲目

    private var trackList: some View {
        List {
            Section {
                ForEach(tracks) { song in
                    SongRowView(song: song, onPlay: {
                        player.play(songs: tracks, startAt: tracks.firstIndex(of: song) ?? 0)
                    })
                }
            } header: {
                Text("专辑曲目")
            }

            if isLoadingSimilar || !similarSongs.isEmpty {
                Section {
                    ForEach(similarSongs) { song in
                        SongRowView(song: song, onPlay: {
                            player.play(songs: similarSongs, startAt: similarSongs.firstIndex(of: song) ?? 0)
                        })
                    }
                } header: {
                    HStack {
                        Text("相似歌曲")
                        if isLoadingSimilar {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 加载

    private func load() async {
        let token = UUID()
        loadToken = token
        isLoading = true
        errorMessage = nil
        detail = nil
        similarSongs = []
        do {
            let loaded = try await provider.fetchAlbumDetail(id: albumID)
            guard loadToken == token, !Task.isCancelled else { return }
            detail = loaded
            isLoading = false
            await loadSimilar(token: token)
        } catch {
            guard loadToken == token else { return }
            errorMessage = error.ctUserMessage
            isLoading = false
        }
    }

    /// 相似歌曲取专辑第一首；没有可播曲目就跳过，不硬凑
    private func loadSimilar(token: UUID) async {
        guard let first = tracks.first, first.source == .netease else { return }
        isLoadingSimilar = true
        defer {
            if loadToken == token { isLoadingSimilar = false }
        }
        do {
            let loaded = try await provider.fetchSimilarSongs(songID: first.id, limit: 10)
            guard loadToken == token, !Task.isCancelled else { return }
            // 相似列表不该包含自己
            similarSongs = loaded.filter { $0.id != first.id }
        } catch {
            guard loadToken == token else { return }
            // 相似推荐失败不影响专辑主体，静默降级
            similarSongs = []
        }
    }

    private func toggleSubscribe(_ subscribe: Bool) async {
        do {
            try await provider.subscribeAlbum(id: albumID, subscribe: subscribe)
            isSubscribed = subscribe
        } catch {
            errorMessage = error.ctUserMessage
        }
    }
}
