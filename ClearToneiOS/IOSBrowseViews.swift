import SwiftUI

struct IOSDiscoverView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var topLists = TopListSession()
    @State private var playlists: [Playlist] = []
    @State private var daily: [Song] = []
    @State private var error: String?
    @State private var dailyError: String?
    @State private var loading = false
    @State private var refreshID = UUID()
    @State private var generation = UUID()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    Label("每天，发现一点喜欢", systemImage: "sparkles").font(.subheadline.weight(.medium)).foregroundStyle(IOSTheme.accent)
                    Text("让好音乐，回到耳边。").font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    Text("从一张歌单开始，找到此刻的心情。").font(.subheadline).foregroundStyle(.secondary)
                    if !appState.isLoggedIn {
                        Button { appState.isLoginPresented = true } label: { Label("登录，开启每日推荐", systemImage: "person.crop.circle") }.buttonStyle(IOSPrimaryButtonStyle())
                    } else if !daily.isEmpty {
                        NavigationLink { IOSSongListView(title: "每日推荐", songs: daily) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "calendar").font(.title2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("你的每日推荐").font(.headline)
                                    Text("\(daily.count) 首，为今天准备").font(.caption)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right")
                            }.padding(16).foregroundStyle(.white).background(IOSTheme.accent, in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }
                    if let dailyError { IOSFailure(message: dailyError) { refreshID = UUID() } }
                }.frame(maxWidth: .infinity, alignment: .leading).iosCard()
                topListSection
                VStack(alignment: .leading, spacing: 16) {
                    IOSSectionHeading(title: "精选歌单", subtitle: "不同的声音，同样的好心情")
                    if loading, playlists.isEmpty { ProgressView("正在获取推荐…").frame(maxWidth: .infinity).padding(32) }
                    if let error { IOSFailure(message: error) { refreshID = UUID() }.iosCard() }
                    if typeSize.isAccessibilitySize {
                        LazyVStack(spacing: 16) { ForEach(playlists) { IOSPlaylistRow(playlist: $0) } }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 230), spacing: 16)], alignment: .leading, spacing: 24) {
                            ForEach(playlists) { IOSPlaylistCard(playlist: $0) }
                        }
                    }
                    if !loading, error == nil, playlists.isEmpty {
                        ContentUnavailableView("暂无推荐歌单", systemImage: "music.note.list", description: Text("下拉刷新，再发现新的音乐"))
                    }
                }
            }.padding(20).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
        .background(IOSTheme.background)
        .navigationTitle("发现")
        .refreshable { await load() }
        .task(id: "\(appState.dataContextKey)-\(refreshID)") { await load(reset: true) }
        .task { await topLists.load() }
    }

    /// 排行榜目录。榜单本身就是歌单，点进去复用 `IOSCollectionView`。
    ///
    /// 加载/失败/重试三态都要渲染：失败时保留旧目录（见 `TopListSession.load`），
    /// 所以错误提示与列表可以同时出现。
    @ViewBuilder
    private var topListSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            IOSSectionHeading(title: "排行榜", subtitle: "此刻大家都在听")
            if topLists.isLoading {
                ProgressView("正在获取榜单…").frame(maxWidth: .infinity).padding(24)
            }
            if let error = topLists.errorMessage {
                IOSFailure(message: error) { Task { await topLists.load() } }
            }
            LazyVStack(spacing: 0) {
                ForEach(topLists.lists) { list in
                    NavigationLink { IOSCollectionView(kind: .playlist(list.id)) } label: {
                        HStack(spacing: 12) {
                            IOSCover(url: list.coverURL, size: 56)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(list.name).lineLimit(2).foregroundStyle(.primary)
                                Text(topListSubtitle(list)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func topListSubtitle(_ list: TopList) -> String {
        let parts: [String?] = [
            list.updateFrequency,
            list.trackCount > 0 ? "\(list.trackCount) 首" : nil,
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
    private func load(reset: Bool = false) async {
        let context = appState.dataContextKey
        let token = UUID(); generation = token
        loading = true; error = nil; dailyError = nil
        if reset { playlists = []; daily = [] }
        defer { if generation == token { loading = false } }
        do {
            let found = try await NeteaseProvider.shared.fetchRecommendPlaylists()
            guard !Task.isCancelled, context == appState.dataContextKey, generation == token else { return }
            playlists = found
        } catch {
            guard !Task.isCancelled, context == appState.dataContextKey, generation == token else { return }
            self.error = error.ctUserMessage
        }
        guard appState.isLoggedIn, !Task.isCancelled, context == appState.dataContextKey, generation == token else { return }
        do {
            let songs = try await NeteaseProvider.shared.fetchDailyRecommendSongs()
            guard !Task.isCancelled, context == appState.dataContextKey, generation == token else { return }
            daily = songs
        } catch {
            guard !Task.isCancelled, context == appState.dataContextKey, generation == token else { return }
            dailyError = error.ctUserMessage
        }
    }
}

struct IOSSearchView: View {
    @StateObject private var session = SearchSession()
    @StateObject private var assist = SearchAssistStore()
    @State private var clearingHistory = false
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerController
    @State private var type: SearchType = .song
    var body: some View {
        List {
            Picker("搜索类型", selection: $type) { ForEach(SearchType.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if session.isLoading { ProgressView("正在搜索…") }
            if let error = session.errorMessage { IOSFailure(message: error) { session.retry(type: type) } }
            if let result = session.result, !session.isLoading, session.errorMessage == nil {
                if result.isEmpty { ContentUnavailableView.search(text: session.activeQuery ?? "") }
                switch session.displayType {
                case .song:
                    ForEach(Array(result.songs.enumerated()), id: \.offset) { index, song in
                        IOSSongRow(song: song) { player.play(songs: result.songs, startAt: index) }
                    }
                case .playlist: ForEach(result.playlists) { IOSPlaylistRow(playlist: $0) }
                case .album:
                    ForEach(result.albums) { album in
                        NavigationLink { IOSCollectionView(kind: .album(album.id)) } label: {
                            HStack { IOSCover(url: album.coverURL); Text(album.name) }
                        }
                    }
                case .artist:
                    ForEach(result.artists) { artist in
                        NavigationLink { IOSCollectionView(kind: .artist(artist.id)) } label: {
                            HStack { IOSCover(url: artist.avatarURL); Text(artist.displayNameWithAlias) }
                        }
                    }
                }
                if result.hasMore { Button("加载更多") { session.loadMore() }.disabled(session.isLoadingMore) }
                // 分页状态必须显式渲染：`loadMore()` 用的是 `isLoadingMore`/`paginationError`，
                // 与整页搜索的 `isLoading`/`errorMessage` 是两套。
                // 只看后者的话，分页失败时界面上**什么都没有** —— 用户点「加载更多」
                // 毫无反应，也没有重试入口（同一个 store，评论页与详情页都渲染了这两项）。
                if session.isLoadingMore { ProgressView().frame(maxWidth: .infinity) }
                if let error = session.paginationError { IOSFailure(message: error) { session.loadMore() } }
            } else if !session.isLoading, session.errorMessage == nil {
                if !assist.suggestions.isEmpty, !session.draftQuery.isEmpty {
                    Section("搜索建议") {
                        ForEach(assist.suggestions) { suggestion in
                            Button { search(suggestion.title) } label: { Label(suggestion.title, systemImage: "magnifyingglass").foregroundStyle(.primary) }
                        }
                    }
                } else if session.draftQuery.isEmpty {
                    if !assist.history.isEmpty {
                        Section {
                            ForEach(assist.history, id: \.self) { query in
                                Button { search(query) } label: { Label(query, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary) }
                                    .swipeActions { Button("删除", role: .destructive) { assist.removeHistory(query) } }
                            }
                        } header: {
                            HStack { Text("最近搜索"); Spacer(); Button("清除") { clearingHistory = true } }
                        }
                    }
                    hotSearchSection
                    if assist.history.isEmpty, assist.hotTerms.isEmpty,
                       !assist.isLoadingHot, assist.hotError == nil {
                        ContentUnavailableView("下一首喜欢，从这里开始", systemImage: "magnifyingglass", description: Text("输入歌曲、歌手、专辑或歌单名称，点击键盘上的搜索"))
                    }
                } else {
                    ContentUnavailableView("下一首喜欢，从这里开始", systemImage: "magnifyingglass", description: Text("输入歌曲、歌手、专辑或歌单名称，点击键盘上的搜索"))
                }
            }
        }
        .navigationTitle("搜索")
        .searchable(text: $session.draftQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "歌曲、歌手、专辑、歌单")
        .onSubmit(of: .search) { search(session.draftQuery) }
        .onChange(of: type) { _, _ in if session.hasActiveQuery { search(session.draftQuery) } }
        .onChange(of: session.draftQuery) { _, value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { session.reset(); assist.clearSuggestions() }
            else { assist.querySuggestions(value) }
        }
        .onChange(of: appState.dataContextKey) { _, _ in session.refreshDataContext(type: type) }
        .onDisappear { session.cancelInFlight(); assist.clearSuggestions() }
        .task { await assist.loadHotTerms() }
        .confirmationDialog("清除最近搜索？", isPresented: $clearingHistory, titleVisibility: .visible) {
            Button("清除历史", role: .destructive) { assist.clearHistory() }
        }
    }

    /// 热门搜索。`loadHotTerms()` 的三个状态都要渲染 ——
    /// 只看 `hotTerms` 的话，加载中与失败都是「一片空白」，用户看不出区别，
    /// 失败后也没有重试入口。没有内容时整块不显示，由下面的空态兜住。
    @ViewBuilder
    private var hotSearchSection: some View {
        if assist.isLoadingHot || assist.hotError != nil || !assist.hotTerms.isEmpty {
            Section {
                if assist.isLoadingHot {
                    ProgressView("正在获取热搜…")
                } else if let error = assist.hotError {
                    IOSFailure(message: error) { Task { await assist.loadHotTerms() } }
                } else {
                    ForEach(assist.hotTerms) { term in
                        Button { search(term.keyword) } label: {
                            HStack(spacing: 6) {
                                if let icon = term.icon, !icon.isEmpty { Text(icon) }
                                Text(term.keyword).foregroundStyle(.primary)
                            }
                        }
                    }
                }
            } header: { Text("热门搜索") }
        }
    }
    private func search(_ query: String) {
        session.draftQuery = query
        assist.recordSearch(query)
        assist.clearSuggestions()
        session.submit(type: type)
    }
}

struct IOSCollectionView: View {
    let kind: MobileCollectionSession.Kind
    @StateObject private var session = MobileCollectionSession()
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerController
    @State private var refreshID = UUID()
    @State private var expandedDescription = false
    var body: some View {
        List {
            Section {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                layout {
                    IOSCover(url: session.coverURL, size: 104)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(session.title).font(.title3.bold())
                        Text("\(session.songs.count) 首已加载").font(.caption).foregroundStyle(.secondary)
                        Button("播放全部", systemImage: "play.fill") { player.play(songs: session.songs) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(session.songs.isEmpty)
                    }
                }.padding(.vertical, 8)
                if let text = session.descriptionText, !text.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(expandedDescription ? nil : 3)
                        Button(expandedDescription ? "收起简介" : "展开简介") { expandedDescription.toggle() }.font(.caption.weight(.semibold))
                    }
                }
            }
            if session.isLoading { ProgressView("加载曲目…") }
            if let error = session.errorMessage {
                IOSFailure(message: error) {
                    if session.songs.isEmpty { refreshID = UUID() }
                    else { Task { await session.loadMore() } }
                }
            }
            Section("歌曲") {
                // 取快照：翻页会让 `session.songs` 整体变长，而闭包是**点击时**才执行 ——
                // 直接读实时数组的话，`index` 可能已经指向另一首歌（越界由 PlayQueue
                // 兜住不会崩，但会从错误的位置开始播）。快照与当前渲染的行严格对应。
                let songs = session.songs
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                    IOSSongRow(song: song) { player.play(songs: songs, startAt: index) }
                }
                if session.hasMore { Button("加载更多曲目") { Task { await session.loadMore() } }.disabled(session.isLoadingMore) }
                if session.isLoadingMore { ProgressView() }
                if session.songs.isEmpty, !session.isLoading, session.errorMessage == nil { Text("暂无歌曲").foregroundStyle(.secondary) }
            }
            if !session.albums.isEmpty {
                Section("专辑") {
                    ForEach(session.albums) { album in
                        NavigationLink { IOSCollectionView(kind: .album(album.id)) } label: { HStack { IOSCover(url: album.coverURL); Text(album.name) } }
                    }
                }
            }
        }
        .navigationTitle(session.title).navigationBarTitleDisplayMode(.inline)
        .task(id: "\(kind)-\(appState.dataContextKey)-\(refreshID)") { await session.load(kind) }
        .refreshable { await session.load(kind) }
        .onDisappear { session.cancel() }
    }
}

struct IOSSongListView: View {
    let title: String
    let songs: [Song]
    @EnvironmentObject private var player: PlayerController
    var body: some View {
        List {
            if songs.isEmpty { ContentUnavailableView("暂无歌曲", systemImage: "music.note") }
            else {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("\(songs.count) 首歌曲").font(.subheadline).foregroundStyle(.secondary)
                        Button("播放全部", systemImage: "play.fill") { player.play(songs: songs) }.buttonStyle(IOSPrimaryButtonStyle())
                    }.padding(.vertical, 8)
                }
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in IOSSongRow(song: song) { player.play(songs: songs, startAt: index) } }
            }
        }.navigationTitle(title)
    }
}
