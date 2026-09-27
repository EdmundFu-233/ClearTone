import SwiftUI
import UniformTypeIdentifiers

struct SearchView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    /// 搜索状态机（草稿/已提交分离 + 在途请求代次隔离），见 SearchSession
    @StateObject private var session = SearchSession()
    @StateObject private var assist = SearchAssistStore()
    @State private var searchType: SearchType = .song
    @State private var isShowingAssist = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            typePicker

            // 结果区
            if session.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = session.errorMessage {
                ErrorView(message: error) {
                    session.retry(type: searchType)
                }
            } else if let result = session.result {
                if result.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "没有找到相关结果",
                        message: "试试更短的关键词，或切换搜索类型"
                    )
                } else {
                    SearchResultList(
                        result: result,
                        type: session.displayType,
                        onLoadMore: { session.loadMore() }
                    )
                }
            } else {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "搜索音乐",
                    message: "输入关键词搜索歌曲、歌手、专辑或歌单"
                )
            }
        }
        .background(CTColors.background(for: colorScheme))
        .onAppear {
            // 工具栏的搜索框与 `appState.searchQuery` 双向绑定，所以这里能直接读到
            // 「用户在工具栏里敲了什么」。
            //
            // 不要清空它：清空会让工具栏的输入框在离开搜索页后又变空，
            // 而搜索页里还留着上次的关键词 —— 界面与状态对不上。
            // 只有当它与已提交的查询不同时才需要发起新查询。
            let incoming = appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !incoming.isEmpty else { return }
            if session.activeQuery != incoming {
                session.draftQuery = incoming
                submit()
            } else {
                session.draftQuery = incoming
            }
        }
        .onDisappear {
            session.cancelInFlight()
        }
        .onChange(of: appState.dataContextKey) { _, _ in
            // 登录态切换：重搜，避免展示上一个账号的结果
            session.refreshDataContext(type: searchType)
        }
    }

    // MARK: - 搜索栏（含热搜/历史/联想面板）

    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索歌曲、歌手、专辑、歌单", text: $session.draftQuery)
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
                    .onSubmit { submit() }
                    .onChange(of: session.draftQuery) { _, newValue in
                        // 只在获得焦点时展示下拉，避免切页后残留一个浮层
                        isShowingAssist = isFieldFocused
                        if isFieldFocused { assist.querySuggestions(newValue) }
                    }
                if !session.draftQuery.isEmpty {
                    Button {
                        // 键盘清空和点 × 必须走同一条路径：
                        // 早期只让 × 调 resetSearch，导致用键盘删空后
                        // 再切分类会命中「关键词为空 → 不搜索」而显示空白页
                        session.reset()
                        assist.clearSuggestions()
                        isShowingAssist = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索")
                }
            }
            .padding(CTSpacing.md)
            .ctGlassSurface()

            if isShowingAssist {
                SearchAssistPanel(
                    keyword: session.draftQuery,
                    onPick: { term in
                        session.draftQuery = term
                        isShowingAssist = false
                        isFieldFocused = false
                        submit()
                    },
                    onPickSuggestion: { suggestion in
                        isShowingAssist = false
                        isFieldFocused = false
                        open(suggestion)
                    },
                    onClose: closeAssist,
                    store: assist
                )
                .padding(.horizontal, CTSpacing.lg)
                .padding(.top, CTSpacing.xs)
                .transition(.opacity)
            }
        }
        .padding(CTSpacing.lg)
        .padding(.bottom, isShowingAssist ? 0 : CTSpacing.lg)
        .task { await assist.loadHotTerms() }
    }

    // MARK: - 类型选择

    private var typePicker: some View {
        Picker("类型", selection: $searchType) {
            ForEach(SearchType.allCases, id: \.self) { type in
                Text(type.rawValue).tag(type)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, CTSpacing.lg)
        .padding(.bottom, CTSpacing.md)
        .onChange(of: searchType) { _, _ in
            isShowingAssist = false
            // 关键词为空时也要重置已提交的结果，
            // 否则会显示上一个关键词在这个类型下的结果
            if session.draftQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                session.reset()
            } else {
                submit()
            }
        }
    }

    // MARK: - 动作

    /// 收起联想下拉。面板的关闭按钮与 Esc 都走这里。
    ///
    /// 必须连输入框焦点一起撤掉：面板的显示条件是 `isShowingAssist`，
    /// 而它由 `draftQuery` 的 onChange 同步成 `isFieldFocused` ——
    /// 焦点还在的话，用户接着打字面板会立刻弹回来。
    private func closeAssist() {
        isShowingAssist = false
        isFieldFocused = false
    }

    private func submit() {
        let keyword = session.draftQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        assist.recordSearch(keyword)
        // 回写全局关键词：工具栏的输入框绑定在它上面，
        // 不回写的话用户离开搜索页再回来，工具栏会是空的
        appState.searchQuery = keyword
        session.submit(type: searchType)
    }

    /// 联想项直接跳到对应详情页（而不是把它当关键词再搜一次）
    private func open(_ suggestion: SearchSuggestion) {
        switch suggestion.kind {
        case .song:
            // 歌曲联想只给 id 和简要信息，拉详情再播
            session.draftQuery = suggestion.title
            searchType = .song
            submit()
        case .artist:
            appState.openArtist(suggestion.targetID)
        case .album:
            appState.openAlbum(suggestion.targetID)
        case .playlist:
            appState.openPlaylist(suggestion.targetID)
        }
    }
}

struct SearchResultList: View {
    let result: SearchResult
    let type: SearchType
    let onLoadMore: () -> Void
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                switch type {
                case .song:
                    ForEach(result.songs) { song in
                        SongRowView(song: song, onPlay: {
                            player.play(songs: result.songs, startAt: result.songs.firstIndex(of: song) ?? 0)
                        })
                        .onAppear { triggerLoadMoreIfNeeded(song.id) }
                    }
                case .artist:
                    // 歌手/专辑/歌单此前只渲染裸 Text，点不进去也看不出封面。
                    // 三者现在都是可点的卡片，并各自触发分页。
                    grid {
                        ForEach(result.artists) { artist in
                            ArtistCardView(artist: artist) {
                                appState.openArtist(artist.id)
                            }
                            .onAppear { triggerLoadMoreIfNeeded(artist.id) }
                        }
                    }
                case .album:
                    grid {
                        ForEach(result.albums) { album in
                            AlbumCardView(album: album) {
                                appState.openAlbum(album.id)
                            }
                            .onAppear { triggerLoadMoreIfNeeded(album.id) }
                        }
                    }
                case .playlist:
                    ForEach(result.playlists) { playlist in
                        PlaylistRowView(playlist: playlist) {
                            appState.openPlaylist(playlist.id)
                        }
                        .onAppear { triggerLoadMoreIfNeeded(playlist.id) }
                    }
                }
            }
            .padding(.bottom, CTSpacing.xl)
        }
    }

    /// 三种非单曲类型共用同一套网格布局。
    ///
    /// 不能写成 `grid(of:content:)` 泛型形式：`@ViewBuilder` 产生的闭包是
    /// non-escaping，而 ForEach 需要 escaping 闭包，Swift 会直接拒绝编译。
    @ViewBuilder
    private func grid(@ViewBuilder content: () -> some View) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130), spacing: CTSpacing.lg)],
            spacing: CTSpacing.lg
        ) {
            content()
                .padding(.horizontal, CTSpacing.lg)
                .padding(.top, CTSpacing.md)
        }
    }

    /// 滚到最后一项就加载下一页 —— 此前只有单曲分支接了 onLoadMore，
    /// 于是歌手/专辑/歌单永远停在第一页 30 条。
    private func triggerLoadMoreIfNeeded(_ id: String) {
        guard result.hasMore else { return }
        switch type {
        case .song: if id == result.songs.last?.id { onLoadMore() }
        case .artist: if id == result.artists.last?.id { onLoadMore() }
        case .album: if id == result.albums.last?.id { onLoadMore() }
        case .playlist: if id == result.playlists.last?.id { onLoadMore() }
        }
    }
}

struct SongRowView: View {
    let song: Song
    let onPlay: () -> Void
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovering = false
    @State private var showAddToPlaylist = false

    private var isLiked: Bool { appState.isLiked(song.id) }

    var body: some View {
        HStack(spacing: CTSpacing.md) {
            // 封面
            CoverImage(url: song.coverURL, size: 40) {
                RoundedRectangle(cornerRadius: CTRadius.small)
                    .fill(CTColors.overlay(for: colorScheme))
                    .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
            }
            .frame(width: 40, height: 40)
            .cornerRadius(CTRadius.small)

            // 信息
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(CTTypography.bodyMedium)
                    .foregroundStyle(
                        song.isPlayable ? CTColors.textPrimary(for: colorScheme) : CTColors.textSecondary(for: colorScheme)
                    )
                    .lineLimit(1)

                HStack(spacing: CTSpacing.xs) {
                    if !song.isPlayable, let reason = song.unavailableReason {
                        Text(reason)
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.accent(for: colorScheme))
                    }
                    Text(song.artistNames)
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        .lineLimit(1)
                }
            }

            Spacer()

            // 收藏
            if song.source == .netease {
                Button(action: { Task { await appState.toggleLike(song) } }) {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.body)
                        .foregroundStyle(isLiked ? CTColors.accent(for: colorScheme) : CTColors.textSecondary(for: colorScheme))
                }
                .buttonStyle(.plain)
                .disabled(!appState.canPerformWrite)
                .opacity(appState.isLoggedIn ? 1 : 0.4)
                .help(heartHelpText)
                .accessibilityLabel(isLiked ? "取消收藏" : "收藏")
            }

            // 时长
            Text(formatDuration(song.duration))
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                .monospacedDigit()

            // 播放按钮
            if song.isPlayable {
                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(CTColors.accent(for: colorScheme))
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0.65)
                .accessibilityLabel("播放：\(song.title)")
            }
        }
        .padding(.horizontal, CTSpacing.lg)
        .padding(.vertical, CTSpacing.sm)
        .background(player.currentSong?.id == song.id ? CTColors.accentSubtle(for: colorScheme) : (isHovering ? CTColors.overlay(for: colorScheme) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: CTRadius.medium))
        .onHover { isHovering = $0 }
        // 双击整行播放。放在行上而不是 List 上，这样每个列表各自决定
        // 「这一行的播放」是什么语义（队列替换 vs 追加）。
        // contentShape 确保空白区域也能接收点击，否则只有文字/图片命中。
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard song.isPlayable else { return }
            onPlay()
        }
        .contextMenu { songContextMenu }
        // 拖到队列面板上入队。载荷类型的编解码只在 `SongTransfer` 一处定义
        // （Playback/SongTransfer.swift），不会因为两个地方各写一份而对不上。
        .draggable(SongTransfer(song: song))
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(songs: [song])
                .environmentObject(appState)
                .environmentObject(player)
        }
    }

    @ViewBuilder
    private var songContextMenu: some View {
        Button("立即播放") { onPlay() }.disabled(!song.isPlayable)
        Button("下一首播放") { player.insertNext(song) }
        Button("添加到队列") { player.appendToQueue(song) }

        if song.source == .netease {
            Divider()
            Button(isLiked ? "取消收藏" : "收藏到喜欢的音乐") {
                Task { await appState.toggleLike(song) }
            }
            .disabled(!appState.canPerformWrite)

            Button("添加到歌单…") { showAddToPlaylist = true }
                .disabled(!appState.canPerformWrite)

            Button("查看评论") { appState.openComments(for: song) }
        }
    }

    private var heartHelpText: String {
        guard appState.isLoggedIn else { return "登录后可收藏" }
        return isLiked ? "取消收藏" : "收藏到喜欢的音乐"
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct PlaylistRowView: View {
    let playlist: Playlist
    var isSubscribed: Bool? = nil
    var onTap: (() -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button { onTap?() } label: {
        HStack(spacing: CTSpacing.md) {
            CoverImage(url: playlist.coverURL, size: 48) {
                RoundedRectangle(cornerRadius: CTRadius.small)
                    .fill(CTColors.overlay(for: colorScheme))
                    .overlay(Image(systemName: "music.note.list").foregroundStyle(.secondary))
            }
            .frame(width: 48, height: 48)
            .cornerRadius(CTRadius.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(CTTypography.bodyMedium)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    .lineLimit(1)
                HStack(spacing: CTSpacing.xs) {
                    Text("\(playlist.trackCount) 首")
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    if let creator = playlist.creatorName, !creator.isEmpty {
                        Text("· \(creator)")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            .lineLimit(1)
                    }
                    if isSubscribed == true {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(CTColors.accent(for: colorScheme))
                            .help("已收藏")
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, CTSpacing.lg)
        .padding(.vertical, CTSpacing.sm)
        .contentShape(Rectangle())
        .background(isHovering ? CTColors.overlay(for: colorScheme) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("打开歌单：\(playlist.name)")
    }
}

struct ErrorView: View {
    let message: String
    let retryAction: () -> Void
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: CTSpacing.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(CTColors.accent(for: colorScheme))
            Text(message)
                .font(CTTypography.body)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                .multilineTextAlignment(.center)
            Button(L10n.Common.retry, action: retryAction)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: CTSpacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(CTColors.textSecondary(for: colorScheme).opacity(0.5))
            Text(title)
                .font(CTTypography.sectionTitle)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))
            Text(message)
                .font(CTTypography.body)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
