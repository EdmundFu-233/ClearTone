import SwiftUI

struct SearchView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    @State private var searchText = ""
    @State private var searchType: SearchType = .song
    @State private var result: SearchResult?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var currentPage = 1
    @State private var searchTask: Task<Void, Never>?
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var searchGeneration = 0

    // 当前结果集对应的“已提交”搜索参数；分页只读取这里，不读输入框草稿
    @State private var activeQuery: String?
    @State private var activeType: SearchType?
    @State private var activeIsDemoMode = false

    private let provider = NeteaseProvider.shared
    private let demoProvider = DemoProvider.shared

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            VStack(spacing: CTSpacing.md) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索歌曲、歌手、专辑、歌单", text: $searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { performSearch() }
                    if !searchText.isEmpty {
                        Button(action: resetSearch) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(CTSpacing.md)
                .ctGlassSurface()

                // 类型选择
                Picker("类型", selection: $searchType) {
                    ForEach(SearchType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: searchType) { _, _ in
                    if !searchText.isEmpty { performSearch() }
                }
            }
            .padding(CTSpacing.lg)

            // 结果区
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ErrorView(message: error, retryAction: performSearch)
            } else if let result = result {
                if result.songs.isEmpty && result.artists.isEmpty && result.albums.isEmpty && result.playlists.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "没有找到相关结果", message: "试试更短的关键词，或切换搜索类型")
                } else {
                    SearchResultList(result: result, type: searchType, onLoadMore: loadMore)
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
            if !appState.searchQuery.isEmpty {
                searchText = appState.searchQuery
                appState.searchQuery = ""
                performSearch()
            }
        }
        .onDisappear {
            searchGeneration += 1
            searchTask?.cancel()
            loadMoreTask?.cancel()
        }
        .onChange(of: appState.dataContextKey) { _, _ in
            // 登录/演示状态切换：用新数据源重搜，避免展示上一个数据源的结果
            if activeQuery != nil { performSearch() }
        }
    }

    private func performSearch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // 递增代际并捕获本次搜索参数；旧任务回包时校验代际，结果不再混入
        searchGeneration += 1
        let generation = searchGeneration
        let query = searchText
        let type = searchType
        let useDemo = appState.isDemoMode
        let searchProvider: MusicProvider = useDemo ? demoProvider : provider
        searchTask?.cancel()
        searchTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
        // 记录结果集对应的已提交参数，后续分页固定使用它们
        activeQuery = query
        activeType = type
        activeIsDemoMode = useDemo
        currentPage = 1
        isLoading = true
        errorMessage = nil

        searchTask = Task {
            do {
                let found = try await searchProvider.search(
                    query: query, type: type, page: 1, limit: 30
                )
                if !Task.isCancelled, generation == searchGeneration {
                    self.result = found
                    isLoading = false
                }
            } catch {
                if !Task.isCancelled, generation == searchGeneration {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func loadMore() {
        // 分页只使用已提交查询对应的参数，不读输入框草稿
        guard let result = result, result.hasMore, !isLoading, loadMoreTask == nil,
              let query = activeQuery, let type = activeType else { return }
        let generation = searchGeneration
        let useDemo = activeIsDemoMode
        let searchProvider: MusicProvider = useDemo ? demoProvider : provider
        let page = currentPage + 1
        currentPage = page

        loadMoreTask = Task {
            defer { loadMoreTask = nil }
            do {
                let more = try await searchProvider.search(
                    query: query, type: type, page: page, limit: 30
                )
                // 期间发起了新搜索/清空结果集则丢弃本次分页，避免旧结果混入
                guard generation == searchGeneration else { return }
                var merged = self.result ?? SearchResult()
                merged.songs.append(contentsOf: more.songs)
                merged.hasMore = more.hasMore
                self.result = merged
            } catch {
                guard generation == searchGeneration else { return }
                currentPage = page - 1
            }
        }
    }

    /// 清空搜索框：作废所有在途请求并重置结果/分页/加载态
    private func resetSearch() {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
        activeQuery = nil
        activeType = nil
        result = nil
        currentPage = 1
        isLoading = false
        errorMessage = nil
        searchText = ""
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
                        .onAppear {
                            if song.id == result.songs.last?.id { onLoadMore() }
                        }
                    }
                case .artist:
                    ForEach(result.artists) { artist in
                        Text(artist.name)
                            .font(CTTypography.body)
                            .padding()
                    }
                case .album:
                    ForEach(result.albums) { album in
                        Text(album.name)
                            .font(CTTypography.body)
                            .padding()
                    }
                case .playlist:
                    ForEach(result.playlists) { playlist in
                        PlaylistRowView(playlist: playlist) {
                            appState.selectedPlaylistID = playlist.id
                            appState.currentPage = .playlistDetail
                        }
                    }
                }
            }
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
                .disabled(!appState.isLoggedIn || appState.isDemoMode)
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
        .contextMenu {
            Button("立即播放") { onPlay() }.disabled(!song.isPlayable)
            Button("下一首播放") { player.insertNext(song) }
            Button("添加到队列") { player.appendToQueue(song) }
            if song.source == .netease {
                Divider()
                Button(isLiked ? "取消收藏" : "收藏到喜欢的音乐") {
                    Task { await appState.toggleLike(song) }
                }
                .disabled(!appState.isLoggedIn || appState.isDemoMode)
            }
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
    var onTap: (() -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme

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
                Text("\(playlist.trackCount) 首")
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            }

            Spacer()
        }
        .padding(.horizontal, CTSpacing.lg)
        .padding(.vertical, CTSpacing.sm)
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
