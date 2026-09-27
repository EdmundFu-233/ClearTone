import SwiftUI

/// 歌曲评论页。
///
/// 网易云的评论是社区核心之一，本项目此前完全没有。
/// 读走 `/comment/music`（weapi，歌曲专用）；**写**（发评论 / 删评论）
/// 上游是 xeapi —— 需要运行时公钥与每次现取的反作弊 token，
/// 只有辅助进程能做，所以 iOS 直连不可用，这里显式说明而不是给个假按钮。
struct SongCommentsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var player: PlayerController

    @StateObject private var store = CommentsStore()

    /// 当前查看评论的歌曲。
    ///
    /// 必须读 `appState.commentSong`：这个字段才是「谁点开了评论」的来源。
    /// 原先读的是 `store.song`，而 `store.song` 只由 `store.load(song:)` 写入，
    /// 唯一的 `load` 调用点又要求 `store.song` 已非 nil —— 循环依赖，
    /// 于是请求从未发出，整页永远停在「还没有评论」的空态。
    /// `appState.commentSong` 当时全工程零读取方。
    private var song: Song? { appState.commentSong ?? store.song }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.isLoading {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.errorMessage {
                ErrorView(message: error) { Task { await store.reload() } }
            } else if store.comments.isEmpty {
                EmptyStateView(icon: "text.bubble", title: "评论", message: "还没有评论，来说点什么吧")
            } else {
                list
            }
        }
        .background(CTColors.background(for: colorScheme))
        .task(id: song?.id ?? "") {
            guard let song else { return }
            await store.load(song: song)
        }
        .onChange(of: store.sort) { _, newValue in
            guard let song else { return }
            Task { await store.load(song: song, sort: newValue) }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: CTSpacing.md) {
            HStack(spacing: CTSpacing.lg) {
                CoverImage(url: song?.coverURL, size: 72) {
                    RoundedRectangle(cornerRadius: CTRadius.small)
                        .fill(CTColors.overlay(for: colorScheme))
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: CTRadius.small))

                VStack(alignment: .leading, spacing: 4) {
                    Text(song?.title ?? "评论")
                        .font(CTTypography.pageTitle)
                        .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    Text(song.map { "\($0.artistNames) · \($0.album?.name ?? "")" } ?? "")
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        .lineLimit(1)
                }

                Spacer()

                if let song {
                    Button {
                        player.play(songs: [song], startAt: 0)
                    } label: {
                        Label("播放", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack {
                Picker("排序", selection: $store.sort) {
                    ForEach(CommentSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)

                Spacer()

                Text("\(store.total) 条评论")
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            }

            composerHint
        }
        .padding(CTSpacing.xl)
    }

    /// 发评论入口。
    ///
    /// 上游 `/comment/add` 是 xeapi：需要辅助进程持有运行时公钥并为每次调用
    /// 现取反作弊 token。与其给一个点了没反应的按钮，不如把限制说清楚。
    @ViewBuilder
    private var composerHint: some View {
        if !appState.canPerformWrite {
            Text("登录后可发表评论、点赞")
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
        } else {
            Text("发表评论依赖网易云的反作弊校验，当前版本仅支持阅读与点赞")
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
        }
    }

    // MARK: - 列表

    private var list: some View {
        List {
            ForEach(store.comments) { comment in
                CommentRow(
                    comment: comment,
                    onToggleLike: { Task { await store.toggleLike(comment) } }
                )
                .onAppear {
                    if comment.id == store.comments.last?.id { Task { await store.loadMore() } }
                }
            }
            if store.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView("加载中...").controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, CTSpacing.md)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// 单条评论
struct CommentRow: View {
    let comment: Comment
    let onToggleLike: () -> Void

    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var appState: AppState
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: CTSpacing.md) {
            AvatarView(url: comment.avatarURL, size: 36)

            VStack(alignment: .leading, spacing: CTSpacing.xs) {
                HStack(spacing: CTSpacing.sm) {
                    Text(comment.nickname)
                        .font(CTTypography.bodyMedium)
                        .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    if comment.isMine {
                        Text("我")
                            .font(CTTypography.caption)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(CTColors.accentSubtle(for: colorScheme))
                            .clipShape(Capsule())
                            .foregroundStyle(CTColors.accent(for: colorScheme))
                    }
                    Text(Self.relativeTime(comment.time))
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    Spacer()
                }

                if let nickname = comment.replyToNickname {
                    Text("回复 @\(nickname)：\(comment.replyToContent ?? "")")
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        .lineLimit(2)
                        .padding(CTSpacing.xs)
                        .background(CTColors.overlay(for: colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: CTRadius.small))
                }

                Text(comment.content)
                    .font(CTTypography.body)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: CTSpacing.lg) {
                    Button(action: onToggleLike) {
                        HStack(spacing: 4) {
                            Image(systemName: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            if comment.likedCount > 0 {
                                Text("\(comment.likedCount)")
                                    .monospacedDigit()
                            }
                        }
                        .font(CTTypography.caption)
                        .foregroundStyle(
                            comment.isLiked
                                ? CTColors.accent(for: colorScheme)
                                : CTColors.textSecondary(for: colorScheme)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!appState.canPerformWrite)
                    .help(appState.canPerformWrite ? "赞" : "登录后可点赞")

                    if comment.replyCount > 0 {
                        Label("\(comment.replyCount) 条回复", systemImage: "arrowshape.turn.up.left")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            .help("回复功能尚未接入")
                    }
                }
            }
        }
        .padding(.horizontal, CTSpacing.lg)
        .padding(.vertical, CTSpacing.md)
        .background(isHovering ? CTColors.overlay(for: colorScheme).opacity(0.4) : Color.clear)
        .onHover { isHovering = $0 }
    }

    /// 「刚刚 / 5 分钟前 / 昨天 / 2026-01-01」
    static func relativeTime(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        if seconds < 172800 { return "昨天" }
        if seconds < 604800 { return "\(Int(seconds / 86400)) 天前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
