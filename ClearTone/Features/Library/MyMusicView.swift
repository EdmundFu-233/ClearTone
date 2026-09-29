import SwiftUI

/// 我的音乐页：歌单/专辑/歌手/电台收藏
/// （原在 `App/MainWindow.swift`，按 P2-11 拆出）

struct MyMusicView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var library = LibraryStore()
    @State private var tab: Tab = .playlists
    @State private var showCreatePlaylist = false
    @State private var renameTarget: Playlist?
    @State private var deleteTarget: Playlist?

    enum Tab: String, CaseIterable, Identifiable {
        case songs = "歌曲"
        case playlists = "歌单"
        case albums = "专辑"
        case artists = "歌手"
        case radios = "电台"

        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .songs: return "heart"
            case .playlists: return "music.note.list"
            case .albums: return "square.stack"
            case .artists: return "person.wave.2"
            case .radios: return "dot.radiowaves.left.and.right"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CTPageHeader(title: "我的音乐", subtitle: "收藏的旋律，都在这里。", icon: "music.note.list")
                Spacer()
                if tab == .playlists && appState.canPerformWrite {
                    Button {
                        showCreatePlaylist = true
                    } label: {
                        Label("新建歌单", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(CTSpacing.xl)

            Picker("分区", selection: $tab) {
                ForEach(Tab.allCases) { item in
                    Label(item.rawValue, systemImage: item.systemImage).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, CTSpacing.xl)
            .padding(.bottom, CTSpacing.md)

            if !appState.isLoggedIn {
                LoginRequiredView(feature: "我的音乐")
            } else {
                sectionBody
            }
        }
        .background(CTColors.background(for: colorScheme))
        .task(id: appState.dataContextKey) { await load() }
        .sheet(isPresented: $showCreatePlaylist) {
            PlaylistNameSheet(mode: .create) { name in
                await appState.createPlaylist(name: name, isPrivate: false) != nil
            } onCancel: {
                showCreatePlaylist = false
            }
            .environmentObject(appState)
        }
        .sheet(item: $renameTarget) { playlist in
            PlaylistNameSheet(mode: .rename(playlist)) { name in
                await appState.renamePlaylist(playlist, to: name)
            } onCancel: {
                renameTarget = nil
            }
            .environmentObject(appState)
        }
        .sheet(item: $deleteTarget) { playlist in
            ConfirmDeletePlaylistSheet(playlist: playlist) {
                await appState.deletePlaylist(playlist)
            } onCancel: {
                deleteTarget = nil
            }
            .environmentObject(appState)
        }
        // 写操作失败统一由 MainWindow 的 WriteErrorToast 呈现，
        // 原来这个 alert 会和 toast 重复报同一件事。
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch tab {
        case .songs: songsSection
        case .playlists: playlistsSection
        case .albums, .artists, .radios:
            LibrarySectionView(
                section: tab == .albums ? .albums : (tab == .artists ? .artists : .radios),
                store: library
            )
        }
    }

    // MARK: - 我喜欢的音乐

    @ViewBuilder
    private var songsSection: some View {
        if appState.likedSongs.isEmpty {
            EmptyStateView(icon: "heart", title: "喜欢的音乐", message: "还没有喜欢的歌曲")
        } else {
            List(appState.likedSongs) { song in
                SongRowView(song: song) {
                    let songs = appState.likedSongs
                    player.play(songs: songs, startAt: songs.firstIndex(of: song) ?? 0)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - 我的歌单

    @ViewBuilder
    private var playlistsSection: some View {
        if appState.isLoadingUserPlaylists && appState.userPlaylists.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.userPlaylists.isEmpty {
            VStack(spacing: CTSpacing.lg) {
                EmptyStateView(icon: "music.note.list", title: "我的歌单", message: "还没有创建歌单")
                if appState.canPerformWrite {
                    Button {
                        showCreatePlaylist = true
                    } label: {
                        Label("新建歌单", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: CTSpacing.lg)], spacing: CTSpacing.lg) {
                    LikedPlaylistCard(count: appState.likedSongs.count) {
                        appState.switchToTopLevel(.liked)
                    }
                    ForEach(appState.userPlaylists) { playlist in
                        PlaylistCardView(playlist: playlist) {
                            appState.openPlaylist(playlist.id)
                        }
                        .overlay(alignment: .topTrailing) {
                            PlaylistActionsMenu(
                                playlist: playlist,
                                isOwned: true,
                                isSubscribed: true,
                                onSubscribe: { _ in },
                                onRename: { renameTarget = playlist },
                                onDelete: { deleteTarget = playlist }
                            )
                            .padding(CTSpacing.sm)
                        }
                    }
                }
                .padding(CTSpacing.xl)
            }
        }
    }

    private func load() async {
        async let a: Void = appState.loadLikedSongs()
        async let b: Void = appState.loadUserPlaylists()
        async let c: Void = library.load(isLoggedIn: appState.isLoggedIn)
        _ = await (a, b, c)
    }
}

/// 「我喜欢的音乐」置顶卡片
struct LikedPlaylistCard: View {
    let count: Int
    let onTap: () -> Void
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: CTSpacing.sm) {
            RoundedRectangle(cornerRadius: CTRadius.medium)
                .fill(
                    LinearGradient(
                        colors: [Color.purple.opacity(0.85), Color.blue.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 180)
                .overlay {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.white.opacity(0.9))
                }

            Text("我喜欢的音乐")
                .font(CTTypography.bodyMedium)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                .lineLimit(2)

            Text("\(count) 首")
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
        }
        .contentShape(Rectangle())
        .opacity(isHovering ? 0.85 : 1)
        .onTapGesture(perform: onTap)
        .onHover { isHovering = $0 }
    }
}
