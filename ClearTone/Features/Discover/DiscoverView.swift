import SwiftUI

/// 发现音乐页：每日推荐、推荐歌单
/// （原在 `App/MainWindow.swift`，按 P2-11 拆出）

struct DiscoverView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme
    @State private var recommendedPlaylists: [Playlist] = []
    @State private var dailySongs: [Song] = []
    @State private var isLoading = false
    /// 加载代次：与 PlaylistDetailView / MyMusicView 保持同一套竞态防护
    @State private var loadToken = UUID()

    private let provider = NeteaseProvider.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CTSpacing.xl) {
                CTPageHeader(title: "发现音乐", subtitle: "为今天，找到合适的旋律。", icon: "music.note.house")

                // 快捷入口
                quickEntries

                // 每日推荐（30 首）
                dailySection

                // 推荐歌单
                playlistSection
            }
            .padding(CTSpacing.xl)
        }
        .background(CTColors.background(for: colorScheme))
        .task(id: appState.dataContextKey) { await loadRecommendations() }
    }

    // MARK: - 快捷入口

    private var quickEntries: some View {
        HStack(spacing: CTSpacing.md) {
            quickEntry(title: "排行榜", subtitle: "云音乐飙升榜", icon: "list.number") {
                appState.switchToTopLevel(.topList)
            }
            quickEntry(title: "私人 FM", subtitle: " endless 推荐流", icon: "waveform.badge.magnifyingglass") {
                appState.switchToTopLevel(.personalFM)
            }
            quickEntry(title: "消息", subtitle: "评论与私信", icon: "bell") {
                appState.switchToTopLevel(.messages)
            }
            quickEntry(title: "听歌等级", subtitle: "打卡与排行", icon: "crown") {
                appState.switchToTopLevel(.profile)
            }
        }
    }

    private func quickEntry(
        title: String, subtitle: String, icon: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: CTSpacing.md) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(CTColors.accent(for: colorScheme))
                    .frame(width: 34, height: 34)
                    .background(CTColors.accentSubtle(for: colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: CTRadius.small))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(CTTypography.bodyMedium)
                        .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    Text(subtitle)
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                }
                Spacer(minLength: 0)
            }
            .padding(CTSpacing.md)
            .frame(maxWidth: .infinity)
            .background(CTColors.panel(for: colorScheme), in: RoundedRectangle(cornerRadius: CTRadius.medium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - 每日推荐

    /// 横向卡片区当前可见的歌曲 id。
    ///
    /// 用来判断「还有没有下一屏」以决定 ‹ › 按钮的可用状态 ——
    /// SwiftUI 没有公开的 scroll offset，而 `LazyHStack` 只创建可见的子视图，
    /// 所以卡片的 `onAppear` / `onDisappear` 是唯一可靠的可见性信号。
    @State private var visibleDailyIDs: Set<String> = []

    private var firstVisibleDailyIndex: Int {
        dailySongs.firstIndex { visibleDailyIDs.contains($0.id) } ?? 0
    }

    private var lastVisibleDailyIndex: Int {
        dailySongs.lastIndex { visibleDailyIDs.contains($0.id) } ?? max(dailySongs.count - 1, 0)
    }

    @ViewBuilder
    private var dailySection: some View {
        if !dailySongs.isEmpty {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: CTSpacing.md) {
                    HStack(alignment: .firstTextBaseline, spacing: CTSpacing.sm) {
                        Label("每日推荐", systemImage: "sparkles")
                            .font(CTTypography.sectionTitle)
                            .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                        Text("\(dailySongs.count) 首")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))

                        Spacer()

                        // 显式的翻页按钮。
                        // 只留滚动条是不够的：macOS 的横向 ScrollView 不响应普通
                        // 滚轮与拖拽（手势被外层纵向 ScrollView 吃掉），
                        // 谁也不会想到去拖那条几像素高的细线 ——
                        // 结果就是 30 首歌只有前 6 首看得见。
                        dailyPageButton(proxy: proxy, delta: -1)
                        dailyPageButton(proxy: proxy, delta: 1)

                        Button {
                            player.play(songs: dailySongs)
                        } label: {
                            Label("播放全部", systemImage: "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("播放今日推荐的 \(dailySongs.count) 首")
                    }

                    // 横向卡片，首屏可见 5~6 张
                    // 指示器**必须**留着：它是唯一能用鼠标拖动的把手
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: CTSpacing.md) {
                            ForEach(dailySongs) { song in
                                DailySongCard(song: song) {
                                    player.play(songs: dailySongs,
                                                startAt: dailySongs.firstIndex(of: song) ?? 0)
                                } onDislike: {
                                    Task { await dislike(song) }
                                }
                                .id(song.id)
                                .onAppear { visibleDailyIDs.insert(song.id) }
                                .onDisappear { visibleDailyIDs.remove(song.id) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.visible)
                    .defaultScrollAnchor(.leading)
                    .help("横向滚动查看全部推荐，或用右上角的 ‹ › 翻页")
                }
            }
        }
    }

    /// 横向翻一屏。步长取当前可见张数 —— 写死张数会在宽窗口上留下大片露不出来的卡。
    private func dailyPageButton(proxy: ScrollViewProxy, delta: Int) -> some View {
        let canScroll = delta < 0
            ? firstVisibleDailyIndex > 0
            : lastVisibleDailyIndex < dailySongs.count - 1
        return Button {
            let step = max(1, lastVisibleDailyIndex - firstVisibleDailyIndex + 1)
            let target = min(max(firstVisibleDailyIndex + delta * step, 0), dailySongs.count - 1)
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(dailySongs[target].id, anchor: .leading)
            }
        } label: {
            Image(systemName: delta < 0 ? "chevron.left" : "chevron.right")
                .font(.caption)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!canScroll)
        .help(delta < 0 ? "上一屏" : "下一屏")
    }

    // MARK: - 推荐歌单

    @ViewBuilder
    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: CTSpacing.md) {
            Label("推荐歌单", systemImage: "music.note.list")
                .font(CTTypography.sectionTitle)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if recommendedPlaylists.isEmpty {
                EmptyStateView(
                    icon: "music.note.house",
                    title: "暂无推荐",
                    message: "登录后查看个性化推荐"
                )
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: CTSpacing.lg)], spacing: CTSpacing.lg) {
                    ForEach(recommendedPlaylists) { playlist in
                        PlaylistCardView(playlist: playlist) {
                            appState.openPlaylist(playlist.id)
                        }
                    }
                }
            }
        }
    }

    private func loadRecommendations() async {
        let token = UUID()
        loadToken = token
        isLoading = true

        // 每日推荐与推荐歌单分别成败：歌单挂了不该让每日推荐也消失
        // （实测 /recommend/songs 只需 2s，比歌单更稳）
        async let playlistsTask: Void = loadPlaylists(token: token)
        async let dailyTask: Void = loadDailySongs(token: token)
        _ = await (playlistsTask, dailyTask)

        guard loadToken == token else { return }
        isLoading = false
    }

    private func loadPlaylists(token: UUID) async {
        do {
            let loaded = try await provider.fetchRecommendPlaylists()
            guard loadToken == token, !Task.isCancelled else { return }
            recommendedPlaylists = loaded
        } catch {
            guard loadToken == token else { return }
            CTLog.general.error("加载推荐歌单失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }

    /// 反馈「不喜欢」并用替补歌曲补位。
    /// 失败时不动列表 —— 凭空少一首歌比反馈失败更难解释。
    private func dislike(_ song: Song) async {
        guard appState.canPerformWrite else { return }
        let token = loadToken
        do {
            let replacement = try await provider.dislikeDailyRecommend(songID: song.id)
            guard loadToken == token, !Task.isCancelled else { return }
            guard let index = dailySongs.firstIndex(where: { $0.id == song.id }) else { return }
            if let replacement {
                dailySongs[index] = replacement
            } else {
                dailySongs.remove(at: index)
                visibleDailyIDs.remove(song.id)
            }
        } catch {
            guard loadToken == token else { return }
            CTLog.general.error("反馈不喜欢失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }

    private func loadDailySongs(token: UUID) async {
        do {
            let loaded = try await provider.fetchDailyRecommendSongs()
            guard loadToken == token, !Task.isCancelled else { return }
            dailySongs = loaded
            // 换了一批歌，可见集合必须清空 —— 否则残留的旧 id 会把
            // ‹ › 的可用状态算错（firstIndex 落到别的歌上）
            visibleDailyIDs.removeAll()
        } catch {
            guard loadToken == token else { return }
            // 未登录时网易云返回空数组而非报错，这里兜底成空并静默降级：
            // 每日推荐区块整体不显示，页面其余部分照常
            CTLog.general.error("加载每日推荐失败: \(CTLog.sanitize(error.localizedDescription))")
            dailySongs = []
        }
    }
}

/// 每日推荐单曲卡片：横向滚动的一列小卡，双击或点播放按钮播放
struct DailySongCard: View {
    let song: Song
    let onPlay: () -> Void
    /// 「不喜欢」：反馈给每日推荐，命中后用接口返回的替补歌曲补位
    var onDislike: (() -> Void)?
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovering = false

    private var isCurrent: Bool { player.currentSong?.id == song.id }
    private var isLiked: Bool { appState.isLiked(song.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: CTSpacing.sm) {
            ZStack(alignment: .bottomTrailing) {
                CoverImage(url: song.coverURL, size: 140) {
                    RoundedRectangle(cornerRadius: CTRadius.small)
                        .fill(CTColors.overlay(for: colorScheme))
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.title)
                                .foregroundStyle(.secondary)
                        )
                }
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: CTRadius.small))

                // 悬停时显示播放按钮（每日推荐是快速试听入口，入口要显眼）
                if isHovering || isCurrent {
                    Button {
                        // 正在播这首 → 暂停；否则从它开始播
                        if isCurrent && player.playbackState.isPlaying {
                            player.pause()
                        } else {
                            onPlay()
                        }
                    } label: {
                        Image(systemName: isCurrent && player.playbackState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(CTColors.accent(for: colorScheme).opacity(0.92)))
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .accessibilityLabel(isCurrent && player.playbackState.isPlaying ? "暂停" : "播放：\(song.title)")
                }
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
            .frame(width: 140, alignment: .leading)

            HStack(spacing: CTSpacing.xs) {
                if song.source == .netease {
                    Button {
                        Task { await appState.toggleLike(song) }
                    } label: {
                        Image(systemName: isLiked ? "heart.fill" : "heart")
                            .font(.caption)
                            .foregroundStyle(isLiked ? CTColors.accent(for: colorScheme) : CTColors.textSecondary(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                    .disabled(!appState.isLoggedIn)
                    .accessibilityLabel(isLiked ? "取消收藏" : "收藏")
                }
                Spacer(minLength: 0)
                Text(Self.format(song.duration))
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    .monospacedDigit()
            }
            .frame(width: 140)
        }
        .padding(CTSpacing.sm)
        .background(isCurrent ? CTColors.accentSubtle(for: colorScheme) : (isHovering ? CTColors.overlay(for: colorScheme) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: CTRadius.medium))
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
        // 与其它歌曲列表统一：双击播放
        .onTapGesture(count: 2) {
            guard song.isPlayable else { return }
            onPlay()
        }
        .contextMenu {
            Button("立即播放") { onPlay() }.disabled(!song.isPlayable)
            Button("下一首播放") { player.insertNext(song) }
            Button("添加到队列") { player.appendToQueue(song) }
            if song.source == .netease {
                Divider()
                Button(isLiked ? "取消收藏" : "收藏到喜欢的音乐") {
                    Task { await appState.toggleLike(song) }
                }
                .disabled(!appState.canPerformWrite)
                if let onDislike {
                    Button("不喜欢这首歌", action: onDislike)
                        .disabled(!appState.canPerformWrite)
                }
                Button("查看评论") { appState.openComments(for: song) }
            }
        }
    }

    /// 长音频（电台节目）超过 1 小时显示 时:分:秒，与 RadioProgramRow 保持一致
    static func format(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

struct PlaylistCardView: View {
    let playlist: Playlist
    var onTap: (() -> Void)? = nil
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button { onTap?() } label: {
        VStack(alignment: .leading, spacing: CTSpacing.sm) {
            CoverImage(url: playlist.coverURL, size: 180) {
                RoundedRectangle(cornerRadius: CTRadius.medium)
                    .fill(CTColors.overlay(for: colorScheme))
                    .overlay(Image(systemName: "music.note.list").foregroundStyle(.secondary))
            }
            .frame(height: 180)
            .clipped()
            .cornerRadius(CTRadius.medium)

            Text(playlist.name)
                .font(CTTypography.bodyMedium)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                .lineLimit(2)

            Text("\(playlist.trackCount) 首")
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
        }
        .padding(CTSpacing.md)
        .background(CTColors.panel(for: colorScheme), in: RoundedRectangle(cornerRadius: CTRadius.large))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开歌单：\(playlist.name)")
        .contentShape(Rectangle())
        .opacity(isHovering ? 0.85 : 1)
        .onHover { isHovering = $0 }
    }
}

/// 「我的音乐」：歌曲 / 歌单 / 专辑 / 歌手 / 电台 五个分区。
///
/// 与网易云一致的信息架构：收藏的东西按类型分栏，而不是每个类型一个侧栏入口。
