import SwiftUI

/// 收藏/取消收藏按钮。歌单、专辑、歌手、电台共用。
///
/// 用统一的组件而不是在四个页面各写一遍：
/// 「未登录时禁用 + 说明原因」这条规则很容易漏，漏了就是 spec §8
/// 说的「空壳按钮」。
struct SubscribeButton: View {
    let target: SubscribeTarget
    let title: String
    /// 当前是否已收藏。传 nil 表示未知（如未登录），显示为禁用
    var isSubscribed: Bool?
    var compact: Bool = false
    let onChange: (Bool) async -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var isWorking = false

    private var isEnabled: Bool { appState.canPerformWrite && !isWorking }

    private var label: String {
        if isWorking { return "" }
        return isSubscribed == true ? "已收藏" : title
    }

    var body: some View {
        Button {
            guard isEnabled else { return }
            let targetState = !(isSubscribed ?? false)
            isWorking = true
            Task {
                await onChange(targetState)
                isWorking = false
            }
        } label: {
            HStack(spacing: CTSpacing.xs) {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: (isSubscribed ?? false) ? "checkmark" : "plus")
                }
                if !compact || isSubscribed == true {
                    Text(label).font(CTTypography.body)
                }
            }
        }
        .buttonStyle(.bordered)
        .disabled(!isEnabled)
        .help(helpText)
        .accessibilityLabel(label.isEmpty ? "处理中" : label)
    }

    private var helpText: String {
        if !appState.isLoggedIn { return "登录后可收藏" }
        return isSubscribed == true ? "取消收藏\(target.displayName)" : "收藏到「我的\(target.displayName)」"
    }
}

/// 歌手卡片（搜索结果 / 相似歌手 / 资料库共用）
struct ArtistCardView: View {
    let artist: Artist
    var coverURL: URL? = nil
    var subtitle: String? = nil
    let onTap: () -> Void

    @Environment(\.colorScheme) var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: CTSpacing.sm) {
                CoverImage(url: coverURL, size: 120) {
                    Circle()
                        .fill(CTColors.overlay(for: colorScheme))
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.title)
                                .foregroundStyle(.secondary)
                        )
                }
                .frame(width: 120, height: 120)
                .clipShape(Circle())

                Text(artist.name)
                    .font(CTTypography.bodyMedium)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        .lineLimit(1)
                }
            }
            .frame(width: 120, alignment: .leading)
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 0.85 : 1)
        .onHover { isHovering = $0 }
        .accessibilityLabel("查看歌手：\(artist.name)")
    }
}

/// 专辑卡片（搜索结果 / 新碟上架 / 歌手专辑 / 资料库共用）
struct AlbumCardView: View {
    let album: Album
    var subtitle: String? = nil
    let onTap: () -> Void

    @Environment(\.colorScheme) var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: CTSpacing.sm) {
                CoverImage(url: album.coverURL, size: 120) {
                    RoundedRectangle(cornerRadius: CTRadius.small)
                        .fill(CTColors.overlay(for: colorScheme))
                        .overlay(Image(systemName: "square.stack").foregroundStyle(.secondary))
                }
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: CTRadius.small))

                Text(album.name)
                    .font(CTTypography.bodyMedium)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    .lineLimit(2)

                if let subtitle {
                    Text(subtitle)
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        .lineLimit(1)
                }
            }
            .frame(width: 120, alignment: .leading)
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 0.85 : 1)
        .onHover { isHovering = $0 }
        .accessibilityLabel("查看专辑：\(album.name)")
    }
}

/// 需要登录才能用的功能的统一提示。
///
/// 单独抽出来是因为这类提示很容易写成「假装能点」的空壳按钮；
/// 这里直接给一个明确的行动入口（去登录）。
struct LoginRequiredView: View {
    let feature: String
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: CTSpacing.lg) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(CTColors.textSecondary(for: colorScheme).opacity(0.5))
            Text("登录后使用\(feature)")
                .font(CTTypography.sectionTitle)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))
            Text("\(feature)属于账号数据，扫码登录后即可使用。")
                .font(CTTypography.body)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                .multilineTextAlignment(.center)

            // 只置位，不自己呈现：登录弹窗的唯一呈现点是工具栏的 AccountButton
            // （见 AppState.isLoginPresented 的注释）
            Button("扫码登录") { appState.isLoginPresented = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(CTSpacing.xl)
    }
}

/// 带分页加载的网格容器。滚动到底自动加载下一页。
struct InfiniteScrollGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let hasMore: Bool
    let isLoading: Bool
    let onLoadMore: () -> Void
    let minimumItemWidth: CGFloat
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: minimumItemWidth), spacing: CTSpacing.lg)],
                spacing: CTSpacing.lg
            ) {
                ForEach(items) { item in
                    content(item)
                        .onAppear {
                            if item.id == items.last?.id { onLoadMore() }
                        }
                }
            }
            .padding(CTSpacing.lg)

            if isLoading {
                ProgressView()
                    .padding(.vertical, CTSpacing.lg)
            } else if hasMore && !items.isEmpty {
                // 还没滚到底但已加载完：给一个显式按钮，不靠滚动触发
                Button("加载更多") { onLoadMore() }
                    .buttonStyle(.bordered)
                    .padding(.bottom, CTSpacing.lg)
            }
        }
    }
}
