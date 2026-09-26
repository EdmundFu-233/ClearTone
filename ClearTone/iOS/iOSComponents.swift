import SwiftUI
#if os(iOS)
import UIKit
#endif

// ============================================================
// iOS 侧的基础 UI 组件
//
// 刻意不复用 macOS 的 Features/* 与 CoverImage：那些文件依赖
// NSWindow / MenuBarExtra / AppKit 的 NSImage，跨平台抽象的成本
// 高于收益。iOS 侧重写一套触控优先的组件。
// ============================================================

/// 封面图。走 iOS 版 `CoverLoader`（含 https 升级 + host 故障转移）。
struct CoverTile<Placeholder: View>: View {
    let url: URL?
    let size: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AsyncCoverImage(url: url, size: size, placeholder: placeholder())
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: CTRadius.small))
    }
}

extension CoverTile where Placeholder == AnyView {
    init(url: URL?, size: CGFloat, @ViewBuilder placeholder: @escaping () -> AnyView) {
        self.init(url: url, size: size, placeholder: placeholder)
    }
}

/// 实际加载逻辑
private struct AsyncCoverImage<Placeholder: View>: View {
    let url: URL?
    let size: CGFloat
    let placeholder: Placeholder
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if let image {
                #if os(iOS)
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                #else
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                #endif
            } else {
                placeholder
            }
        }
        .task(id: url?.absoluteString) {
            image = await CoverLoader.shared.load(url: url, pointSize: size)
        }
    }
}

/// 歌曲行。触控优先：整行点击播放，右侧心形与更多菜单。
struct SongRow: View {
    let song: Song
    let onPlay: () -> Void

    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var isCurrent: Bool { player.currentSong?.id == song.id }
    private var isLiked: Bool { appState.isLiked(song.id) }

    var body: some View {
        HStack(spacing: CTSpacing.md) {
            CoverTile(url: song.coverURL, size: 48) {
                AnyView(
                    RoundedRectangle(cornerRadius: CTRadius.small)
                        .fill(CTColors.overlay(for: colorScheme))
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundStyle(.secondary)
                        )
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(CTTypography.bodyMedium)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    .lineLimit(1)
                Text(song.artistNames)
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if song.source == .netease {
                Button {
                    Task { await appState.toggleLike(song) }
                } label: {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .foregroundStyle(
                            isLiked ? CTColors.accent(for: colorScheme)
                                    : CTColors.textSecondary(for: colorScheme)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!appState.isLoggedIn || appState.isDemoMode)
                .accessibilityLabel(isLiked ? "取消收藏" : "收藏")
            }

            Text(Self.format(song.duration))
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                .monospacedDigit()
        }
        .padding(.horizontal, CTSpacing.lg)
        .padding(.vertical, CTSpacing.sm)
        .listRowBackground(
            isCurrent ? CTColors.accentSubtle(for: colorScheme) : Color.clear
        )
        .contentShape(Rectangle())
        // iOS 用单击（列表行没有「双击」惯例）
        .onTapGesture(perform: onPlay)
        .contextMenu {
            Button("立即播放") { onPlay() }.disabled(!song.isPlayable)
            Button("下一首播放") { player.insertNext(song) }
            Button("添加到队列") { player.appendToQueue(song) }
        }
    }

    /// 超过 1 小时显示 时:分:秒（电台节目）
    static func format(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

/// 页面标题
struct PageTitle: View {
    let title: String
    var subtitle: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(CTTypography.pageTitle)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))
            if let subtitle {
                Text(subtitle)
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 空状态
struct EmptyState: View {
    let icon: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: CTSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(CTTypography.bodyMedium)
            if let message {
                Text(message)
                    .font(CTTypography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
