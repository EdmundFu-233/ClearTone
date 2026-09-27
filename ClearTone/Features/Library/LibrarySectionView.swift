import SwiftUI

/// 「我的音乐」的资料库分区：收藏的专辑 / 关注歌手 / 收藏电台。
///
/// 网易云把这三块放在「我的音乐」里而不是独立 Tab，本项目沿用同一信息架构。
struct LibrarySectionView: View {
    let section: LibraryStore.Section
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    @ObservedObject var store: LibraryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CTSpacing.lg) {
                if store.failedSections.contains(section) {
                    ErrorView(message: "加载\(section.title)失败") {
                        Task { await store.load(isLoggedIn: appState.isLoggedIn) }
                    }
                    .frame(height: 180)
                } else if isEmpty {
                    EmptyStateView(
                        icon: section.systemImage,
                        title: "暂无\(section.title)",
                        message: emptyMessage
                    )
                    .frame(minHeight: 200)
                } else {
                    content
                }
            }
            .padding(CTSpacing.xl)
        }
    }

    private var isEmpty: Bool {
        switch section {
        case .albums: return store.albums.isEmpty
        case .artists: return store.artists.isEmpty
        case .radios: return store.radios.isEmpty
        }
    }

    private var emptyMessage: String {
        guard appState.canPerformWrite else { return "登录后查看你的\(section.title)收藏" }
        switch section {
        case .albums: return "在专辑页点「收藏专辑」就会出现在这里"
        case .artists: return "在歌手页点「关注歌手」就会出现在这里"
        case .radios: return "在电台页点「收藏电台」就会出现在这里"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .albums:
            LazyVGrid(columns: columns, spacing: CTSpacing.lg) {
                ForEach(store.albums) { album in
                    AlbumCardView(album: album) { appState.openAlbum(album.id) }
                        .contextMenu {
                            Button("取消收藏", role: .destructive) {
                                Task { await store.unsubscribe(.album(album.id), name: album.name) }
                            }
                        }
                }
            }
        case .artists:
            LazyVGrid(columns: columns, spacing: CTSpacing.lg) {
                ForEach(store.artists) { artist in
                    ArtistCardView(artist: artist) { appState.openArtist(artist.id) }
                        .contextMenu {
                            Button("取消关注", role: .destructive) {
                                Task { await store.unsubscribe(.artist(artist.id), name: artist.name) }
                            }
                        }
                }
            }
        case .radios:
            LazyVGrid(columns: columns, spacing: CTSpacing.lg) {
                ForEach(store.radios) { radio in
                    RadioCollectionCard(station: radio) {
                        appState.openRadio(radio.id)
                    }
                    .contextMenu {
                        Button("取消收藏", role: .destructive) {
                            Task { await store.unsubscribe(.radio(radio.id), name: radio.name) }
                        }
                    }
                }
            }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 140), spacing: CTSpacing.lg)]
    }
}

/// 收藏电台用的紧凑卡片（复用 RadioCardView 的视觉但尺寸更小）
struct RadioCollectionCard: View {
    let station: RadioStation
    let onTap: () -> Void
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: CTSpacing.sm) {
                CoverImage(url: station.coverURL, size: 140) {
                    RoundedRectangle(cornerRadius: CTRadius.medium)
                        .fill(CTColors.overlay(for: colorScheme))
                        .overlay(
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.title)
                                .foregroundStyle(.secondary)
                        )
                }
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: CTRadius.medium))

                Text(station.name)
                    .font(CTTypography.bodyMedium)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    .lineLimit(2)

                Text("\(station.programCount) 期节目")
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            }
            .frame(width: 140, alignment: .leading)
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 0.85 : 1)
        .onHover { isHovering = $0 }
        .accessibilityLabel("打开电台：\(station.name)")
    }
}
