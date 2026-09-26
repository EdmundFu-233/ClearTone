import SwiftUI

// ============================================================
// iOS 的四个页面
//
// 数据来源与 macOS 版完全一致（NeteaseProvider），差别只在
// iOS 走直连而非辅助进程。加载代次（loadToken）防护也照搬：
// 快速来回切页时旧请求不得覆盖新结果。
// ============================================================

// MARK: - 发现

struct DiscoverPage: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerController
    @Environment(\.colorScheme) private var colorScheme

    @State private var dailySongs: [Song] = []
    @State private var playlists: [Playlist] = []
    @State private var isLoading = false
    @State private var loadToken = UUID()

    private let provider = NeteaseProvider.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CTSpacing.xl) {
                    PageTitle(title: "发现音乐", subtitle: "为今天，找到合适的旋律。")

                    if !dailySongs.isEmpty {
                        dailySection
                    }
                    playlistSection
                }
                .padding(CTSpacing.lg)
            }
            .background(CTColors.background(for: colorScheme))
            .navigationTitle("发现")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .task(id: appState.dataContextKey) { await load() }
        }
    }

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: CTSpacing.md) {
            HStack {
                PageTitle(title: "每日推荐", subtitle: nil)
                Button {
                    player.play(songs: dailySongs)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(CTTypography.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: CTSpacing.md) {
                    ForEach(dailySongs) { song in
                        DailyCard(song: song) {
                            player.play(songs: dailySongs,
                                        startAt: dailySongs.firstIndex(of: song) ?? 0)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: CTSpacing.md) {
            PageTitle(title: "推荐歌单", subtitle: nil)
            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(30)
            } else if playlists.isEmpty {
                EmptyState(icon: "music.note.house", title: "暂无推荐",
                           message: appState.isLoggedIn ? nil : "登录后查看个性化推荐")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: CTSpacing.md)],
                          spacing: CTSpacing.md) {
                    ForEach(playlists) { playlist in
                        PlaylistTile(playlist: playlist)
                    }
                }
            }
        }
    }

    private func load() async {
        let token = UUID()
        loadToken = token
        isLoading = true
        // 两块内容分别成败：任一失败不牵连另一方
        async let a: Void = loadDaily(token: token)
        async let b: Void = loadPlaylists(token: token)
        _ = await (a, b)
        guard loadToken == token else { return }
        isLoading = false
    }

    private func loadDaily(token: UUID) async {
        guard let loaded = try? await provider.fetchDailyRecommendSongs() else { return }
        guard loadToken == token, !Task.isCancelled else { return }
        dailySongs = loaded
    }

    private func loadPlaylists(token: UUID) async {
        guard let loaded = try? await provider.fetchRecommendPlaylists() else { return }
        guard loadToken == token, !Task.isCancelled else { return }
        playlists = loaded
    }
}

/// 每日推荐卡片
private struct DailyCard: View {
    let song: Song
    let onPlay: () -> Void
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: CTSpacing.xs) {
            CoverTile(url: song.coverURL, size: 130) {
                AnyView(
                    RoundedRectangle(cornerRadius: CTRadius.small)
                        .fill(CTColors.overlay(for: colorScheme))
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                )
            }
            .overlay(alignment: .bottomTrailing) {
                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, CTColors.accent(for: colorScheme))
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel("播放：\(song.title)")
            }

            Text(song.title)
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
            Text(song.artistNames)
                .font(.caption2)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
        }
    }
}

private struct PlaylistTile: View {
    let playlist: Playlist
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: CTSpacing.xs) {
            CoverTile(url: playlist.coverURL, size: 150) {
                AnyView(
                    RoundedRectangle(cornerRadius: CTRadius.small)
                        .fill(CTColors.overlay(for: colorScheme))
                        .overlay(Image(systemName: "music.note.list").foregroundStyle(.secondary))
                )
            }
            Text(playlist.name)
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                .lineLimit(2)
        }
    }
}

// MARK: - 我的音乐

struct MyMusicPage: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerController
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: Kind = .liked

    enum Kind: String, CaseIterable, Identifiable {
        case liked = "喜欢的音乐"
        case playlists = "我的歌单"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selection) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, CTSpacing.lg)
                .padding(.bottom, CTSpacing.sm)

                switch selection {
                case .liked: likedList
                case .playlists: playlistList
                }
            }
            .background(CTColors.background(for: colorScheme))
            .navigationTitle("我的音乐")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: appState.dataContextKey) {
                await appState.loadLikedSongs()
                await appState.loadUserPlaylists()
            }
        }
    }

    @ViewBuilder
    private var likedList: some View {
        if appState.likedSongs.isEmpty {
            EmptyState(icon: "heart", title: "还没有收藏",
                       message: appState.isLoggedIn ? "去发现页找几首喜欢的歌" : "登录后查看收藏")
        } else {
            List {
                ForEach(appState.likedSongs) { song in
                    SongRow(song: song) {
                        player.play(songs: appState.likedSongs,
                                    startAt: appState.likedSongs.firstIndex(of: song) ?? 0)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var playlistList: some View {
        if appState.userPlaylists.isEmpty {
            EmptyState(icon: "music.note.list", title: "还没有歌单")
        } else {
            List(appState.userPlaylists) { playlist in
                HStack(spacing: CTSpacing.md) {
                    CoverTile(url: playlist.coverURL, size: 44) {
                        AnyView(
                            RoundedRectangle(cornerRadius: CTRadius.small)
                                .fill(CTColors.overlay(for: colorScheme))
                                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                        )
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name)
                            .font(CTTypography.bodyMedium)
                            .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                            .lineLimit(1)
                        Text("\(playlist.trackCount) 首")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - 搜索

struct SearchPage: View {
    @EnvironmentObject private var player: PlayerController
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var results: [Song] = []
    @State private var isSearching = false
    @State private var hasSearched = false

    private let provider = NeteaseProvider.shared

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    ProgressView()
                } else if results.isEmpty {
                    EmptyState(icon: "magnifyingglass", title: "搜索歌曲",
                               message: hasSearched ? "没有找到结果" : nil)
                } else {
                    List {
                        ForEach(results) { song in
                            SongRow(song: song) {
                                player.play(songs: results,
                                            startAt: results.firstIndex(of: song) ?? 0)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(CTColors.background(for: colorScheme))
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "歌曲名或歌手")
            .onSubmit(of: .search) { Task { await search() } }
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSearching = true
        defer { isSearching = false; hasSearched = true }
        results = (try? await provider.search(query: text, type: .song, page: 1, limit: 50).songs) ?? []
    }
}

// MARK: - 电台

struct RadioPage: View {
    @EnvironmentObject private var player: PlayerController
    @Environment(\.colorScheme) private var colorScheme
    @State private var categories: [RadioCategory] = []
    @State private var stations: [RadioStation] = []
    @State private var selectedCategory: String?
    @State private var isLoading = false
    @State private var loadToken = UUID()
    @State private var selectedRadioID: String?

    private let provider = NeteaseProvider.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CTSpacing.lg) {
                    categoryBar
                    if isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(30)
                    } else if stations.isEmpty {
                        EmptyState(icon: "waveform", title: "暂无电台")
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: CTSpacing.md)],
                                  spacing: CTSpacing.md) {
                            ForEach(stations) { station in
                                stationCard(station)
                            }
                        }
                    }
                }
                .padding(CTSpacing.lg)
            }
            .background(CTColors.background(for: colorScheme))
            .navigationTitle("电台")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .task(id: appState_context) { await load() }
            .navigationDestination(item: $selectedRadioID) { id in
                RadioDetailPage(radioID: id)
            }
        }
    }

    /// 让分类变化触发重载
    private var appState_context: String { selectedCategory ?? "all" }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CTSpacing.sm) {
                chip(title: "全部", isOn: selectedCategory == nil) { selectedCategory = nil }
                ForEach(categories) { category in
                    chip(title: category.name, isOn: selectedCategory == category.id) {
                        selectedCategory = category.id
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CTTypography.caption)
                .padding(.horizontal, CTSpacing.md)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(
                        isOn ? CTColors.accent(for: colorScheme) : CTColors.overlay(for: colorScheme)
                    )
                )
                .foregroundStyle(
                    isOn ? Color.white : CTColors.textPrimary(for: colorScheme)
                )
        }
        .buttonStyle(.plain)
    }

    private func stationCard(_ station: RadioStation) -> some View {
        VStack(alignment: .leading, spacing: CTSpacing.xs) {
            CoverTile(url: station.coverURL, size: 150) {
                AnyView(
                    RoundedRectangle(cornerRadius: CTRadius.small)
                        .fill(CTColors.overlay(for: colorScheme))
                        .overlay(Image(systemName: "waveform").foregroundStyle(.secondary))
                )
            }
            Text(station.name)
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                .lineLimit(2)
        }
        .onTapGesture { selectedRadioID = station.id }
    }

    private func load() async {
        let token = UUID()
        loadToken = token
        isLoading = true
        defer { if loadToken == token { isLoading = false } }

        if categories.isEmpty {
            categories = (try? await provider.fetchRadioCategories()) ?? []
        }
        let list: [RadioStation]?
        if let selectedCategory {
            list = try? await provider.fetchHotRadios(categoryID: selectedCategory, limit: 30)
        } else {
            list = try? await provider.fetchRecommendedRadios(limit: 30)
        }
        guard loadToken == token, !Task.isCancelled else { return }
        stations = list ?? []
    }
}

/// 电台详情：节目列表
struct RadioDetailPage: View {
    let radioID: String
    @EnvironmentObject private var player: PlayerController
    @Environment(\.colorScheme) private var colorScheme
    @State private var programs: [RadioProgram] = []
    @State private var isLoading = true
    @State private var loadToken = UUID()

    private let provider = NeteaseProvider.shared

    private var playable: [RadioProgram] {
        programs.filter { $0.song != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView().frame(maxHeight: .infinity)
            } else if playable.isEmpty {
                EmptyState(icon: "waveform", title: "该电台还没有节目")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(playable) { program in
                            SongRow(song: program.song!) {
                                player.play(songs: playable.compactMap(\.song),
                                            startAt: playable.firstIndex(of: program) ?? 0)
                            }
                        }
                    } header: {
                        HStack {
                            Text("节目 · \(playable.count) 期")
                            Spacer()
                            Button("播放全部") {
                                player.play(songs: playable.compactMap(\.song))
                            }
                            .font(CTTypography.caption)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(CTColors.background(for: colorScheme))
        .navigationTitle("电台")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: radioID) { await load() }
    }

    private func load() async {
        let token = UUID()
        loadToken = token
        isLoading = true
        defer { if loadToken == token { isLoading = false } }
        let loaded = (try? await provider.fetchRadioPrograms(radioID: radioID, page: 1, limit: 30)) ?? []
        guard loadToken == token, !Task.isCancelled else { return }
        // 按时间倒序，最新的节目在前
        programs = loaded.sorted { (a: RadioProgram, b: RadioProgram) in
            (a.createTime ?? .distantPast) > (b.createTime ?? .distantPast)
        }
    }
}
