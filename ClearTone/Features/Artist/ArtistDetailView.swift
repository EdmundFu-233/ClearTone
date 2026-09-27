import SwiftUI

/// 歌手详情页。
///
/// 与专辑页同理：`fetchArtistDetail` 早已实现（三个接口串联），
/// 但此前没有 UI 入口，搜索结果里的歌手点进去是死的。
struct ArtistDetailView: View {
    let artistID: String
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    @State private var detail: ArtistDetail?
    @State private var similarArtists: [Artist] = []
    @State private var isLoading = false
    @State private var isLoadingSimilar = false
    @State private var errorMessage: String?
    @State private var isSubscribed: Bool?
    @State private var loadToken = UUID()

    private let provider = NeteaseProvider.shared

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ErrorView(message: error) { Task { await load() } }
            } else if detail == nil {
                EmptyStateView(icon: "person.wave.2", title: "歌手", message: "歌手不存在")
            } else {
                header
                Divider()
                content
            }
        }
        .background(CTColors.background(for: colorScheme))
        .task(id: "\(artistID)-\(appState.dataContextKey)") { await load() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: CTSpacing.lg) {
            Circle()
                .fill(CTColors.overlay(for: colorScheme))
                .frame(width: 140, height: 140)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.secondary)
                )

            VStack(alignment: .leading, spacing: CTSpacing.sm) {
                Text(detail?.artist.name ?? "歌手")
                    .font(CTTypography.pageTitle)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                Text("\(detail?.hotSongs.count ?? 0) 首热门 · \(detail?.albums.count ?? 0) 张专辑")
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))

                HStack(spacing: CTSpacing.md) {
                    Button {
                        player.play(songs: detail?.hotSongs ?? [], startAt: 0)
                    } label: {
                        Label("播放热门", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(detail?.hotSongs.isEmpty ?? true)

                    SubscribeButton(
                        target: .artist(artistID),
                        title: "关注歌手",
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

    // MARK: - 正文

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CTSpacing.xl) {
                if let albums = detail?.albums, !albums.isEmpty {
                    VStack(alignment: .leading, spacing: CTSpacing.md) {
                        Label("专辑", systemImage: "square.stack")
                            .font(CTTypography.sectionTitle)
                            .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: CTSpacing.lg) {
                                ForEach(albums) { album in
                                    AlbumCardView(album: album) {
                                        appState.openAlbum(album.id)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if isLoadingSimilar || !similarArtists.isEmpty {
                    VStack(alignment: .leading, spacing: CTSpacing.md) {
                        HStack {
                            Label("相似歌手", systemImage: "person.2")
                                .font(CTTypography.sectionTitle)
                                .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                            if isLoadingSimilar {
                                ProgressView().controlSize(.small).scaleEffect(0.6)
                            }
                        }
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: CTSpacing.lg) {
                                ForEach(similarArtists) { artist in
                                    ArtistCardView(artist: artist) {
                                        appState.openArtist(artist.id)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if let songs = detail?.hotSongs, !songs.isEmpty {
                    VStack(alignment: .leading, spacing: CTSpacing.sm) {
                        Label("热门歌曲", systemImage: "music.note")
                            .font(CTTypography.sectionTitle)
                            .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                        ForEach(songs) { song in
                            SongRowView(song: song, onPlay: {
                                player.play(songs: songs, startAt: songs.firstIndex(of: song) ?? 0)
                            })
                        }
                    }
                }
            }
            .padding(CTSpacing.xl)
        }
    }

    // MARK: - 加载

    private func load() async {
        let token = UUID()
        loadToken = token
        isLoading = true
        errorMessage = nil
        detail = nil
        similarArtists = []
        do {
            let loaded = try await provider.fetchArtistDetail(id: artistID)
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

    private func loadSimilar(token: UUID) async {
        isLoadingSimilar = true
        defer { if loadToken == token { isLoadingSimilar = false } }
        do {
            let loaded = try await provider.fetchSimilarArtists(artistID: artistID)
            guard loadToken == token, !Task.isCancelled else { return }
            similarArtists = loaded.filter { $0.id != artistID }.prefix(12).map { $0 }
        } catch {
            guard loadToken == token else { return }
            similarArtists = []
        }
    }

    private func toggleSubscribe(_ subscribe: Bool) async {
        do {
            try await provider.subscribeArtist(id: artistID, subscribe: subscribe)
            isSubscribed = subscribe
        } catch {
            errorMessage = error.ctUserMessage
        }
    }
}
