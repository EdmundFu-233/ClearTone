import SwiftUI

/// 排行榜页。
///
/// 网易云首页的「排行榜」是一个独立 Tab，本项目此前完全没有这个入口。
/// 榜单在网易云里**本身就是歌单**（`/api/toplist` 返回的 id 可以直接喂给
/// `/playlist/detail`），所以榜单曲目复用了歌单的分页读取。
struct TopListView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    @StateObject private var store = TopListStore()
    @State private var tab: Tab = .charts

    enum Tab: String, CaseIterable, Identifiable {
        case charts = "榜单"
        case newSongs = "新歌速递"
        case square = "歌单广场"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            CTPageHeader(title: "排行榜", subtitle: "看看大家都在听什么。", icon: "list.number")
                .padding(CTSpacing.xl)

            Picker("分类", selection: $tab) {
                ForEach(Tab.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, CTSpacing.xl)
            .padding(.bottom, CTSpacing.md)
            .onChange(of: tab) { _, newValue in
                Task { await load(for: newValue) }
            }

            Group {
                switch tab {
                case .charts: chartsTab
                case .newSongs: newSongsTab
                case .square: squareTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(CTColors.background(for: colorScheme))
        .task { await load(for: tab) }
    }

    // MARK: - 榜单

    @ViewBuilder
    private var chartsTab: some View {
        VStack(spacing: 0) {
            if store.isLoadingLists {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.listsError {
                ErrorView(message: error) { Task { await store.loadLists() } }
            } else if store.lists.isEmpty {
                EmptyStateView(icon: "list.number", title: "排行榜", message: "暂无榜单数据")
            } else {
                HStack(spacing: 0) {
                    listSidebar
                    Divider()
                    trackPane
                }
            }
        }
    }

    private var listSidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CTSpacing.sm) {
                ForEach(store.lists) { list in
                    Button {
                        Task { await store.loadTracks(for: list) }
                    } label: {
                        HStack(spacing: CTSpacing.sm) {
                            CoverImage(url: list.coverURL, size: 40) {
                                RoundedRectangle(cornerRadius: CTRadius.small)
                                    .fill(CTColors.overlay(for: colorScheme))
                                    .overlay(Image(systemName: "list.number").foregroundStyle(.secondary))
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: CTRadius.small))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(list.name)
                                    .font(CTTypography.bodyMedium)
                                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                                    .lineLimit(1)
                                if let freq = list.updateFrequency {
                                    Text(freq)
                                        .font(CTTypography.caption)
                                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(CTSpacing.sm)
                        .background(
                            store.loadedListID == list.id
                                ? CTColors.accentSubtle(for: colorScheme)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: CTRadius.medium))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看榜单：\(list.name)")
                }
            }
            .padding(CTSpacing.md)
        }
        .frame(width: 240)
    }

    @ViewBuilder
    private var trackPane: some View {
        if store.isLoadingTracks {
            ProgressView("加载中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.tracksError {
            ErrorView(message: error) {
                if let id = store.loadedListID,
                   let list = store.lists.first(where: { $0.id == id }) {
                    Task { await store.loadTracks(for: list) }
                }
            }
        } else if store.tracks.isEmpty {
            EmptyStateView(icon: "list.number", title: "榜单", message: "选择左侧榜单查看曲目")
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("\(store.tracks.count) 首")
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    Spacer()
                    Button {
                        player.play(songs: store.tracks, startAt: 0)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, CTSpacing.lg)
                .padding(.vertical, CTSpacing.sm)

                List(store.tracks) { song in
                    SongRowView(song: song) {
                        player.play(songs: store.tracks, startAt: store.tracks.firstIndex(of: song) ?? 0)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - 新歌速递

    @ViewBuilder
    private var newSongsTab: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("地区", selection: Binding(
                    get: { store.newSongsArea },
                    set: { area in Task { await store.loadNewSongs(area: area) } }
                )) {
                    ForEach(TopSongArea.allCases) { area in
                        Text(area.rawValue).tag(area)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                Spacer()

                if !store.newSongs.isEmpty {
                    Button {
                        player.play(songs: store.newSongs, startAt: 0)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, CTSpacing.xl)
            .padding(.bottom, CTSpacing.md)

            if store.isLoadingNewSongs {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.newSongs.isEmpty {
                EmptyStateView(icon: "music.note.list", title: "新歌速递", message: "暂无数据，稍后再试")
            } else {
                List(store.newSongs) { song in
                    SongRowView(song: song) {
                        player.play(songs: store.newSongs, startAt: store.newSongs.firstIndex(of: song) ?? 0)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - 歌单广场

    @ViewBuilder
    private var squareTab: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: CTSpacing.sm) {
                    categoryChip(title: "全部", value: nil)
                    ForEach(store.playlistCategories, id: \.name) { group in
                        ForEach(group.categories, id: \.self) { category in
                            categoryChip(title: category, value: category)
                        }
                    }
                }
                .padding(.horizontal, CTSpacing.xl)
                .padding(.bottom, CTSpacing.sm)
            }

            HStack {
                Picker("排序", selection: $store.playlistOrder) {
                    ForEach(TopPlaylistOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                .onChange(of: store.playlistOrder) { _, _ in
                    Task { await store.loadHotPlaylists(reset: true) }
                }
                Spacer()
            }
            .padding(.horizontal, CTSpacing.xl)
            .padding(.bottom, CTSpacing.sm)

            if store.isLoadingPlaylists && store.hotPlaylists.isEmpty {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.hotPlaylists.isEmpty {
                EmptyStateView(icon: "music.note.list", title: "歌单广场", message: "换个分类试试")
            } else {
                InfiniteScrollGrid(
                    items: store.hotPlaylists,
                    hasMore: store.hotPlaylists.count % 30 == 0,
                    isLoading: store.isLoadingPlaylists,
                    onLoadMore: { Task { await store.loadHotPlaylists(reset: false) } },
                    minimumItemWidth: 160
                ) { playlist in
                    PlaylistCardView(playlist: playlist) {
                        appState.openPlaylist(playlist.id)
                    }
                }
            }
        }
    }

    private func categoryChip(title: String, value: String?) -> some View {
        let isSelected = store.selectedCategory == value
        return Button(title) {
            store.selectedCategory = value
            Task { await store.loadHotPlaylists(reset: true) }
        }
        .buttonStyle(.plain)
        .font(CTTypography.caption)
        .padding(.horizontal, CTSpacing.md)
        .padding(.vertical, CTSpacing.xs)
        .background(
            isSelected ? CTColors.accent(for: colorScheme) : CTColors.panel(for: colorScheme)
        )
        .foregroundStyle(isSelected ? .white : CTColors.textSecondary(for: colorScheme))
        .clipShape(Capsule())
    }

    // MARK: - 加载

    private func load(for tab: Tab) async {
        switch tab {
        case .charts:
            await store.loadLists()
        case .newSongs:
            await store.loadNewSongs()
        case .square:
            await store.loadCategories()
            await store.loadHotPlaylists(reset: true)
        }
    }
}
