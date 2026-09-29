import SwiftUI

/// 歌手资料页。
///
/// ## 结构
///
/// 头图（真实头像 / 名字 / 计数 / 播放 / 关注）+ 五个 Tab：
/// 热门 · 全部歌曲 · 专辑 · MV · 歌手详情。
///
/// 早期版本是一个 `ScrollView` 挂三个写死的区块（专辑横滑 ≤20、相似歌手 12、
/// 热门歌曲），没有 MV、没有简介、没有全部歌曲、没有分页，头像还是画出来的
/// `person.fill` 圆盘 —— `Artist` 类型当时只有 `id` + `name`。
///
/// ## 状态归属
///
/// 加载与分页全在 `ArtistProfileSession`（`Core/Artist/`），视图只渲染。
/// 原因见那个文件的注释：`project.yml` 把 `Features/**` 排除在单测之外，
/// 逻辑放在这里就等于没有回归测试。
///
/// 五块内容**各自独立加载、独立失败**：专辑挂了不影响热门歌曲显示。
@MainActor
struct ArtistDetailView: View {
    let artistID: String

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    @StateObject private var session: ArtistProfileSession
    @State private var tab: Tab = .hot
    @State private var isSubscribing = false

    init(artistID: String) {
        self.artistID = artistID
        _session = StateObject(wrappedValue: ArtistProfileSession(artistID: artistID))
    }

    enum Tab: String, CaseIterable, Identifiable {
        case hot = "热门"
        case songs = "全部歌曲"
        case albums = "专辑"
        case mvs = "MV"
        case about = "歌手详情"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .hot: return "flame"
            case .songs: return "music.note.list"
            case .albums: return "square.stack"
            case .mvs: return "play.rectangle"
            case .about: return "person.text.rectangle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if session.isLoadingProfile && session.profile == nil {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = session.profileError, session.profile == nil {
                ErrorView(message: error) { Task { await session.loadProfile() } }
            } else if session.profile == nil {
                EmptyStateView(icon: "person.wave.2", title: "歌手", message: "歌手不存在或已下架")
            } else {
                header
                Divider()
                tabs
            }
        }
        .background(CTColors.background(for: colorScheme))
        .task(id: "\(artistID)-\(appState.dataContextKey)") {
            // 换歌手要作废在途请求并换成新 id；只是登录态变了则原地重置。
            // 两条路径都得走 —— 只判 `switchTo` 的话，「同一个歌手换了账号」
            // 会被它的 `guard newID != artistID` 短路成什么都不做。
            if session.artistID == artistID {
                session.reloadForDataContext()
            } else {
                session.switchTo(artistID: artistID)
            }
            await session.loadProfile()
            await session.loadHighlights()
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: CTSpacing.lg) {
            // 真实头像。`/artist/detail` 的图片字段叫 cover / avatar 而不是 picUrl，
            // `mapArtist` 四个来源都认；拿不到才退回写死的人形图标。
            CoverImage(url: session.profile?.artist.avatarURL, size: 140) {
                Circle()
                    .fill(CTColors.overlay(for: colorScheme))
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.secondary)
                    )
            }
            .frame(width: 140, height: 140)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: CTSpacing.sm) {
                Text(session.profile?.artist.displayNameWithAlias ?? "歌手")
                    .font(CTTypography.pageTitle)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))

                HStack(spacing: CTSpacing.md) {
                    statText("单曲", session.profile?.songCount ?? 0)
                    statText("专辑", session.profile?.albumCount ?? 0)
                    statText("MV", session.profile?.mvCount ?? 0)
                }

                if let brief = session.profile?.briefDescription, !brief.isEmpty {
                    Text(brief)
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        .lineLimit(2)
                        .frame(maxWidth: 520, alignment: .leading)
                }

                if let tags = session.profile?.identifyTags, !tags.isEmpty {
                    HStack(spacing: CTSpacing.xs) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(CTTypography.caption)
                                .padding(.horizontal, CTSpacing.sm)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(CTColors.accentSubtle(for: colorScheme))
                                )
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        }
                    }
                }

                HStack(spacing: CTSpacing.md) {
                    Button {
                        player.play(songs: session.hotSongs, startAt: 0)
                    } label: {
                        Label("播放热门", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.hotSongs.isEmpty)

                    Button {
                        player.play(songs: session.songs, startAt: 0)
                    } label: {
                        Label("播放全部", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .buttonStyle(.bordered)
                    // 「全部歌曲」没加载完时不许播 —— 否则只放得上前 50 首
                    .disabled(session.songs.isEmpty || session.canLoadMoreSongs)

                    SubscribeButton(
                        target: .artist(artistID),
                        title: "关注歌手",
                        // 初值来自 `/artist/album` 响应里回带的 `artist.followed`。
                        // 早期这里是 `Bool?` 且从不初始化，于是永远显示「未关注」。
                        isSubscribed: session.isFollowed
                    ) { newValue in
                        await toggleSubscribe(newValue)
                    }
                }
            }
            Spacer()
        }
        .padding(CTSpacing.xl)
    }

    private func statText(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Text("\(value)")
                .font(CTTypography.captionMedium)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))
            Text(label)
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
        }
    }

    // MARK: - Tab

    private var tabs: some View {
        TabView(selection: $tab) {
            hotTab
                .tabItem { Label(Tab.hot.rawValue, systemImage: Tab.hot.systemImage) }
                .tag(Tab.hot)
            songsTab
                .tabItem { Label(Tab.songs.rawValue, systemImage: Tab.songs.systemImage) }
                .tag(Tab.songs)
            albumsTab
                .tabItem { Label(Tab.albums.rawValue, systemImage: Tab.albums.systemImage) }
                .tag(Tab.albums)
            mvsTab
                .tabItem { Label(Tab.mvs.rawValue, systemImage: Tab.mvs.systemImage) }
                .tag(Tab.mvs)
            aboutTab
                .tabItem { Label(Tab.about.rawValue, systemImage: Tab.about.systemImage) }
                .tag(Tab.about)
        }
        .onChange(of: tab) { _, new in
            // 按需加载：第一次切到某个 Tab 才拉那一份数据。
            // 五个接口全量加载会让首屏多等 2 个 RTT，而用户多半只看其中一块。
            Task { await loadTabIfNeeded(new) }
        }
    }

    private func loadTabIfNeeded(_ target: Tab) async {
        switch target {
        case .hot:
            if session.hotSongs.isEmpty { await session.loadHighlights() }
        case .songs:
            if session.songs.isEmpty { await session.loadSongs() }
        case .albums:
            if session.albums.isEmpty { await session.loadAlbums() }
        case .mvs:
            if session.mvs.isEmpty { await session.loadMVs() }
        case .about:
            if session.intro == nil { await session.loadIntro() }
        }
    }

    // MARK: - 热门

    private var hotTab: some View {
        List {
            if session.hotSongs.isEmpty && session.isLoadingHighlights {
                HStack { ProgressView().frame(maxWidth: .infinity) }
            } else if session.hotSongs.isEmpty {
                Text("暂无热门歌曲")
                    .font(CTTypography.body)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            } else {
                ForEach(session.hotSongs) { song in
                    SongRowView(song: song) {
                        player.play(songs: session.hotSongs,
                                    startAt: session.hotSongs.firstIndex(of: song) ?? 0)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 全部歌曲

    private var songsTab: some View {
        List {
            if let error = session.songsError, session.songs.isEmpty {
                ErrorView(message: error) { Task { await session.loadSongs() } }
                    .frame(minHeight: 240)
            } else if session.songs.isEmpty && session.isLoadingSongs {
                HStack { ProgressView().frame(maxWidth: .infinity) }
            } else if session.songs.isEmpty {
                EmptyStateView(icon: "music.note.list", title: "全部歌曲",
                               message: "该歌手暂无可展示的歌曲")
            } else {
                Section {
                    ForEach(session.songs) { song in
                        SongRowView(song: song) {
                            player.play(songs: session.songs,
                                        startAt: session.songs.firstIndex(of: song) ?? 0)
                        }
                    }
                    paginationFooter(
                        isLoading: session.isLoadingMoreSongs,
                        canLoadMore: session.canLoadMoreSongs,
                        error: session.songsError
                    ) {
                        Task { await session.loadMoreSongs() }
                    }
                } header: {
                    Text(session.songsTotal > session.songs.count
                         ? "已加载 \(session.songs.count) / \(session.songsTotal) 首"
                         : "共 \(session.songs.count) 首")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 专辑

    private var albumsTab: some View {
        Group {
            if let error = session.albumsError, session.albums.isEmpty {
                ErrorView(message: error) { Task { await session.loadAlbums() } }
            } else if session.albums.isEmpty && session.isLoadingAlbums {
                ProgressView("加载中...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.albums.isEmpty {
                EmptyStateView(icon: "square.stack", title: "专辑", message: "暂无专辑")
            } else {
                InfiniteScrollGrid(
                    items: session.albums,
                    hasMore: session.canLoadMoreAlbums,
                    isLoading: session.isLoadingMoreAlbums,
                    onLoadMore: { Task { await session.loadMoreAlbums() } },
                    minimumItemWidth: 120
                ) { album in
                    AlbumCardView(album: album) { appState.openAlbum(album.id) }
                }
            }
        }
    }

    // MARK: - MV

    private var mvsTab: some View {
        List {
            if let error = session.mvsError, session.mvs.isEmpty {
                ErrorView(message: error) { Task { await session.loadMVs() } }
                    .frame(minHeight: 240)
            } else if session.mvs.isEmpty && session.isLoadingMVs {
                HStack { ProgressView().frame(maxWidth: .infinity) }
            } else if session.mvs.isEmpty {
                EmptyStateView(icon: "play.rectangle", title: "MV", message: "暂无 MV")
            } else {
                ForEach(session.mvs) { mv in
                    ArtistMVRow(mv: mv)
                }
                paginationFooter(
                    isLoading: session.isLoadingMoreMVs,
                    canLoadMore: session.canLoadMoreMVs,
                    error: session.mvsError
                ) {
                    Task { await session.loadMoreMVs() }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 歌手详情

    private var aboutTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CTSpacing.xl) {
                if let intro = session.intro {
                    if let brief = intro.briefDescription, !brief.isEmpty {
                        section("简介") {
                            Text(brief)
                                .font(CTTypography.body)
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                                .textSelection(.enabled)
                        }
                    }
                    ForEach(intro.sections) { part in
                        // 上游允许 ti 为空；空标题时不渲染标题行，
                        // 否则会出现一串没有名字的段落
                        section(part.title.isEmpty ? nil : part.title) {
                            Text(part.body)
                                .font(CTTypography.body)
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                                .textSelection(.enabled)
                        }
                    }
                } else if session.isLoadingIntro {
                    ProgressView("加载中...").frame(maxWidth: .infinity)
                } else if let error = session.introError {
                    ErrorView(message: error) { Task { await session.loadIntro() } }
                        .frame(minHeight: 200)
                } else {
                    EmptyStateView(icon: "person.text.rectangle", title: "歌手详情",
                                   message: "暂无介绍")
                }

                if !session.similarArtists.isEmpty {
                    VStack(alignment: .leading, spacing: CTSpacing.md) {
                        Label("相似歌手", systemImage: "person.2")
                            .font(CTTypography.sectionTitle)
                            .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: CTSpacing.lg) {
                                ForEach(session.similarArtists) { artist in
                                    ArtistCardView(artist: artist) {
                                        appState.openArtist(artist.id)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(CTSpacing.xl)
        }
    }

    @ViewBuilder
    private func section(_ title: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: CTSpacing.sm) {
            if let title {
                Text(title)
                    .font(CTTypography.sectionTitle)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 通用

    /// 分页脚。翻页失败时给一个可点的重试，而不是把整页换成错误态 ——
    /// 已加载的 500 首不该因为第 11 页失败就没了。
    @ViewBuilder
    private func paginationFooter(
        isLoading: Bool,
        canLoadMore: Bool,
        error: String?,
        retry: @escaping () -> Void
    ) -> some View {
        VStack(spacing: CTSpacing.sm) {
            if isLoading {
                ProgressView().controlSize(.small)
            } else if let error, canLoadMore {
                HStack(spacing: CTSpacing.sm) {
                    Text(error)
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    Button("重试", action: retry)
                        .buttonStyle(.link)
                        .font(CTTypography.caption)
                }
            } else if canLoadMore {
                Button("加载更多", action: retry)
                    .buttonStyle(.bordered)
            } else if let error {
                // 没有更多了还报错：说明是加载中途失败的残留提示
                Text(error)
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CTSpacing.md)
        .listRowSeparator(.hidden)
    }

    // MARK: - 写操作

    private func toggleSubscribe(_ subscribe: Bool) async {
        guard !isSubscribing else { return }
        isSubscribing = true
        defer { isSubscribing = false }
        do {
            try await appState.social.subscribeArtist(id: artistID, subscribe: subscribe)
            session.setFollowed(subscribe)
        } catch {
            appState.publishWriteError(error)
        }
    }
}

// MARK: - MV 行

/// MV 列表行。`ArtistMV` 的结构与 `Song` 差很多（没有 album / artists 数组），
/// 所以不能复用 `SongRowView`。
private struct ArtistMVRow: View {
    let mv: ArtistMV
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: CTSpacing.md) {
            CoverImage(url: mv.coverURL, size: 64) {
                RoundedRectangle(cornerRadius: CTRadius.small)
                    .fill(CTColors.overlay(for: colorScheme))
                    .overlay(
                        Image(systemName: "play.rectangle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    )
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: CTRadius.small))

            VStack(alignment: .leading, spacing: 2) {
                Text(mv.name)
                    .font(CTTypography.bodyMedium)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    .lineLimit(1)
                HStack(spacing: CTSpacing.sm) {
                    if let artistName = mv.artistName, !artistName.isEmpty {
                        Text(artistName)
                    }
                    if mv.playCount > 0 {
                        Label(Self.playCountText(mv.playCount), systemImage: "play.fill")
                    }
                    if mv.duration > 0 {
                        Text(Self.durationText(mv.duration))
                    }
                }
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            }
            Spacer()
        }
        .padding(.vertical, CTSpacing.xs)
    }

    static func playCountText(_ value: Int) -> String {
        if value >= 100_000_000 { return String(format: "%.1f亿", Double(value) / 100_000_000) }
        if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
        return "\(value)"
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
