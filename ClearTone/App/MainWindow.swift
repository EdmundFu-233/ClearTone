import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.colorScheme) var systemColorScheme

    private var colorScheme: ColorScheme {
        switch settings.settings.themeMode {
        case .system: return systemColorScheme
        case .dark: return .dark
        case .light: return .light
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 240)
                } detail: {
                    VStack(spacing: 0) {
                        ToolbarView()
                        ContentView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                if appState.showQueue {
                    Divider()
                    QueuePanelView()
                        .transition(.move(edge: .trailing))
                }
            }
            PlayerBarView()
        }
        .tint(CTColors.accent(for: colorScheme))
        .frame(minWidth: 960, minHeight: 640)
        .background(CTColors.background(for: colorScheme))
        // 菜单命令（@FocusedObject）需要场景级对象注入
        .focusedSceneObject(appState)
        .preferredColorScheme(settings.settings.themeMode == .system ? nil : (settings.settings.themeMode == .dark ? .dark : .light))
        .environment(\.ctThemeMode, settings.settings.themeMode)
        .sheet(isPresented: $appState.isNowPlayingExpanded) {
            NowPlayingView()
                .environmentObject(player)
                .environmentObject(settings)
                .environmentObject(appState)
        }
    }
}

// MARK: - 侧栏
struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme

    // 歌单数据与加载态统一由 AppState 持有：
    // 原先 SidebarView 与 MyMusicView 各存一份并各自读/写同一个缓存 key，
    // 同一份数据被解码两次写两次，两处可能显示不同内容。
    // 初值也不在这里读盘：@State 的默认值表达式在每次 View 结构体构造时都会求值
    // （只有第一次结果被保留），而 MainWindow 会因播放进度频繁重建。

    var body: some View {
        List(selection: $appState.currentPage) {
            Section("探索") {
                Label(L10n.Sidebar.discover, systemImage: "music.note.house")
                    .tag(AppState.Page.discover)
                Label(L10n.Sidebar.search, systemImage: "magnifyingglass")
                    .tag(AppState.Page.search)
                Label("电台", systemImage: "dot.radiowaves.left.and.right")
                    .tag(AppState.Page.radio)
            }

            Section("资料库") {
                Label(L10n.Sidebar.myMusic, systemImage: "music.note.list")
                    .tag(AppState.Page.myMusic)
                Label(L10n.Sidebar.liked, systemImage: "heart")
                    .tag(AppState.Page.liked)
                Label(L10n.Sidebar.local, systemImage: "folder")
                    .tag(AppState.Page.local)
                Label(L10n.Sidebar.recent, systemImage: "clock")
                    .tag(AppState.Page.recent)
            }

            Section(L10n.Sidebar.playlists) {
                if appState.isLoggedIn && !appState.isDemoMode {
                    if appState.isLoadingUserPlaylists {
                        HStack(spacing: CTSpacing.sm) {
                            ProgressView()
                                .controlSize(.small)
                            Text("加载中...")
                                .font(CTTypography.caption)
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            Spacer()
                        }
                    } else if appState.userPlaylists.isEmpty {
                        Text("暂无歌单")
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            .font(CTTypography.caption)
                    } else {
                        ForEach(appState.userPlaylists) { playlist in
                            Button {
                                appState.selectedPlaylistID = playlist.id
                                appState.currentPage = .playlistDetail
                            } label: {
                                Label(playlist.name, systemImage: "music.note.list")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Text("暂无歌单")
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        .font(CTTypography.caption)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(CTColors.accent(for: colorScheme))
                VStack(alignment: .leading, spacing: 2) {
                    Text("澄音").font(.system(size: 20, weight: .bold))
                    Text("ClearTone").font(CTTypography.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(CTSpacing.xl)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { appState.currentPage = .settings } label: {
                Label("设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(CTSpacing.md)
            }
            .buttonStyle(.plain)
            .padding(CTSpacing.sm)
            .background(CTColors.panel(for: colorScheme))
        }
        .background(CTColors.panel(for: colorScheme))
        .task(id: appState.dataContextKey) { await appState.loadUserPlaylists() }
    }
}

// MARK: - 工具栏
struct ToolbarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: CTSpacing.md) {
            if appState.currentPage == .search {
                Label("搜索音乐", systemImage: "magnifyingglass")
                    .font(CTTypography.bodyMedium)
                    .foregroundStyle(.secondary)
            } else {
                SearchField()
                    .frame(maxWidth: 360)
            }
            Spacer()
            // 演示模式标记（可直接退出）
            if appState.isDemoMode {
                Button { appState.exitDemoMode() } label: {
                    Label("演示模式", systemImage: "theatermasks")
                        .font(CTTypography.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("点击退出演示模式")
            }
            // 账户头像
            AccountButton()
        }
        .padding(.horizontal, CTSpacing.lg)
        .padding(.vertical, CTSpacing.md)
        .background(CTColors.background(for: colorScheme))
    }
}

struct SearchField: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索歌曲、歌手、专辑、歌单", text: $searchText)
                .textFieldStyle(.plain)
                .onSubmit {
                    guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    appState.searchQuery = searchText
                    appState.currentPage = .search
                }
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(CTSpacing.md)
        .ctGlassSurface()
    }
}

/// 固定尺寸远程头像。
/// 不用 AsyncImage：borderless Menu 会按图片固有尺寸布局（曾把工具栏撑成 542×542），
/// 这里加载后重绘/下采样到目标尺寸再显示，任何容器下都不会撑大。
struct AvatarView: View {
    let url: URL?
    var size: CGFloat = 28
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .contentShape(Circle())
        .task(id: url) {
            image = await AvatarLoader.shared.load(url: url, size: size)
        }
    }
}

/// 头像加载 + 内存缓存（主线程完成下采样，避免跨隔离传递 NSImage）
@MainActor
final class AvatarLoader {
    static let shared = AvatarLoader()
    private let cache = NSCache<NSURL, NSImage>()

    private init() { cache.countLimit = 32 }

    func load(url: URL?, size: CGFloat) async -> NSImage? {
        guard let url else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let raw = NSImage(data: data) else { return nil }
        // 直接绘制成圆形：菜单标签会绕过 SwiftUI 的裁剪，只有在图片层裁剪才可靠
        let thumb = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            let src = raw.size
            let side = min(src.width, src.height)
            let srcRect = NSRect(x: (src.width - side) / 2, y: (src.height - side) / 2, width: side, height: side)
            raw.draw(in: rect, from: srcRect, operation: .sourceOver, fraction: 1)
            return true
        }
        cache.setObject(thumb, forKey: url as NSURL)
        return thumb
    }
}

struct AccountButton: View {
    @EnvironmentObject var appState: AppState
    @State private var showLogin = false

    var body: some View {
        Group {
            if appState.isLoggedIn {
                Menu {
                    if let account = appState.account {
                        Text("\(account.nickname)\(account.isVIP ? " · VIP" : "")")
                    }
                    if appState.isDemoMode {
                        Button("退出演示模式") { appState.exitDemoMode() }
                    }
                    Divider()
                    Button("退出登录") { Task { await appState.performLogout() } }
                } label: {
                    AvatarView(url: appState.account?.avatarURL, size: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(appState.account?.nickname ?? "")
            } else {
                Button(action: { showLogin = true }) {
                    AvatarView(url: appState.account?.avatarURL, size: 28)
                }
                .buttonStyle(.plain)
                .help(L10n.Common.login)
            }
        }
        .sheet(isPresented: $showLogin) {
            LoginView()
                .environmentObject(appState)
        }
        .onChange(of: appState.needsReLogin) { _, needs in
            // 会话失效：自动弹出扫码登录
            if needs {
                showLogin = true
                appState.needsReLogin = false
            }
        }
    }
}

// MARK: - 内容区
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Group {
            switch appState.currentPage {
            case .discover:
                DiscoverView()
            case .search:
                SearchView()
            case .myMusic:
                MyMusicView()
            case .liked:
                LikedView()
            case .local:
                LocalMusicView()
            case .recent:
                RecentView()
            case .playlistDetail:
                PlaylistDetailView(playlistID: appState.selectedPlaylistID ?? "")
            case .radio:
                RadioView()
            case .radioDetail:
                RadioDetailView(radioID: appState.selectedRadioID ?? "")
            case .settings:
                SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CTColors.background(for: colorScheme))
    }
}

// MARK: - 占位视图（阶段 A 先保证可构建）
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
    private let demoProvider = DemoProvider.shared

    var activeProvider: MusicProvider {
        appState.isDemoMode ? demoProvider : provider
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CTSpacing.xl) {
                CTPageHeader(title: "发现音乐", subtitle: "为今天，找到合适的旋律。", icon: "music.note.house")

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

    // MARK: - 每日推荐

    @ViewBuilder
    private var dailySection: some View {
        if !dailySongs.isEmpty {
            VStack(alignment: .leading, spacing: CTSpacing.md) {
                HStack(alignment: .firstTextBaseline) {
                    Label("每日推荐", systemImage: "sparkles")
                        .font(CTTypography.sectionTitle)
                        .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    Spacer()
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
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: CTSpacing.md) {
                        ForEach(dailySongs) { song in
                            DailySongCard(song: song) {
                                player.play(songs: dailySongs,
                                            startAt: dailySongs.firstIndex(of: song) ?? 0)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
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
                    message: appState.isDemoMode ? "演示模式暂无推荐内容" : "登录后查看个性化推荐"
                )
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: CTSpacing.lg)], spacing: CTSpacing.lg) {
                    ForEach(recommendedPlaylists) { playlist in
                        PlaylistCardView(playlist: playlist) {
                            appState.selectedPlaylistID = playlist.id
                            appState.currentPage = .playlistDetail
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
            let loaded = try await activeProvider.fetchRecommendPlaylists()
            guard loadToken == token, !Task.isCancelled else { return }
            recommendedPlaylists = loaded
        } catch {
            guard loadToken == token else { return }
            CTLog.general.error("加载推荐歌单失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }

    private func loadDailySongs(token: UUID) async {
        do {
            let loaded = try await activeProvider.fetchDailyRecommendSongs()
            guard loadToken == token, !Task.isCancelled else { return }
            dailySongs = loaded
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
                    .disabled(!appState.isLoggedIn || appState.isDemoMode)
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
                .disabled(!appState.isLoggedIn || appState.isDemoMode)
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

struct MyMusicView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme

    // 歌单数据由 AppState 统一持有（与 SidebarView 共用同一份，见 AppState.userPlaylists）

    var body: some View {
        VStack(spacing: 0) {
            CTPageHeader(title: "我的音乐", subtitle: "收藏的旋律，都在这里。", icon: "music.note.list")
                .padding(CTSpacing.xl)

            if !appState.isLoggedIn && !appState.isDemoMode {
                EmptyStateView(icon: "music.note.list", title: "我的音乐", message: "登录后查看你的歌单")
            } else if appState.isDemoMode {
                EmptyStateView(icon: "music.note.list", title: "我的音乐", message: "演示模式暂无歌单")
            } else if appState.isLoadingUserPlaylists {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.userPlaylists.isEmpty {
                EmptyStateView(icon: "music.note.list", title: "我的歌单", message: "还没有创建歌单")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: CTSpacing.lg)], spacing: CTSpacing.lg) {
                        // 置顶「我喜欢的音乐」
                        LikedPlaylistCard(count: appState.likedSongs.count) {
                            appState.currentPage = .liked
                        }
                        ForEach(appState.userPlaylists) { playlist in
                            PlaylistCardView(playlist: playlist) {
                                appState.selectedPlaylistID = playlist.id
                                appState.currentPage = .playlistDetail
                            }
                        }
                    }
                    .padding(CTSpacing.xl)
                }
                // 这里不是 List，listStyle / scrollContentBackground 都是无效修饰符；
                // 透明背景要显式声明
                .background(Color.clear)
            }
        }
        .background(CTColors.background(for: colorScheme))
        .task(id: appState.dataContextKey) { await load() }
    }

    private func load() async {
        // 喜欢的歌曲仍由 AppState 维护；歌单也一并委托给它，与侧栏共享同一份数据
        await appState.loadLikedSongs()
        await appState.loadUserPlaylists()
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

struct LikedView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    @State private var demoSongs: [Song] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let demoProvider = DemoProvider.shared

    /// 演示模式用内置数据；登录态直接用 AppState 的缓存列表（收藏后即时同步）
    private var songs: [Song] {
        appState.isDemoMode ? demoSongs : appState.likedSongs
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CTPageHeader(title: "喜欢的音乐", subtitle: songs.isEmpty ? "把心动的旋律，留在身边。" : "\(songs.count) 首珍藏 · 随时重温", icon: "heart.fill")
                if !songs.isEmpty {
                    Button { player.play(songs: songs, startAt: 0) } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(CTSpacing.xl)

            if !appState.isLoggedIn && !appState.isDemoMode {
                EmptyStateView(icon: "heart", title: "喜欢的音乐", message: "登录后查看喜欢的歌曲")
            } else if isLoading {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ErrorView(message: error, retryAction: { Task { await load() } })
            } else if songs.isEmpty {
                EmptyStateView(icon: "heart", title: "喜欢的音乐", message: "还没有喜欢的歌曲")
            } else {
                List(songs) { song in
                    SongRowView(song: song, onPlay: {
                        player.play(songs: songs, startAt: songs.firstIndex(of: song) ?? 0)
                    })
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(CTColors.background(for: colorScheme))
        .task(id: appState.dataContextKey) { await load() }
    }

    private func load() async {
        guard appState.isLoggedIn || appState.isDemoMode else { return }
        if appState.isDemoMode {
            isLoading = true
            errorMessage = nil
            do {
                demoSongs = try await demoProvider.fetchLikedSongs()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        } else {
            await appState.loadLikedSongs()
        }
    }
}

struct LocalMusicView: View {
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme
    @State private var localSongs: [Song] = []
    @State private var isImporting = false
    @State private var importError: String?

    private let localProvider = LocalProvider.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.Sidebar.local)
                    .font(CTTypography.pageTitle)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                Spacer()
                Button("导入文件") { importFiles() }
                    .buttonStyle(.bordered)
                Button("导入文件夹") { importFolder() }
                    .buttonStyle(.bordered)
            }
            .padding(CTSpacing.lg)

            if isImporting {
                ProgressView("导入中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = importError {
                ErrorView(message: error, retryAction: { importError = nil })
            } else if localSongs.isEmpty {
                EmptyStateView(icon: "folder", title: "本地音乐", message: "导入音频文件或文件夹开始播放")
            } else {
                List(localSongs) { song in
                    SongRowView(song: song, onPlay: {
                        player.play(songs: localSongs, startAt: localSongs.firstIndex(of: song) ?? 0)
                    })
                }
            }
        }
        .background(CTColors.background(for: colorScheme))
        // 启动时恢复上次导入的本地曲库
        .task { localSongs = await localProvider.restoreLibrary() }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.begin { response in
            guard response == .OK else { return }
            Task {
                isImporting = true
                do {
                    _ = try await localProvider.importFiles(panel.urls)
                    localSongs = await localProvider.allSongs()
                } catch {
                    importError = error.localizedDescription
                }
                isImporting = false
            }
        }
    }

    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                isImporting = true
                do {
                    _ = try await localProvider.scanDirectory(url)
                    localSongs = await localProvider.allSongs()
                } catch {
                    importError = error.localizedDescription
                }
                isImporting = false
            }
        }
    }
}

struct RecentView: View {
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CTPageHeader(
                    title: L10n.Sidebar.recent,
                    subtitle: player.recentlyPlayed.isEmpty ? "听过的歌会出现在这里。" : "最近 \(player.recentlyPlayed.count) 首",
                    icon: "clock"
                )
                if !player.recentlyPlayed.isEmpty {
                    Button { player.play(songs: player.recentlyPlayed, startAt: 0) } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(CTSpacing.xl)

            if player.recentlyPlayed.isEmpty {
                EmptyStateView(icon: "clock", title: "最近播放", message: "暂无播放记录")
            } else {
                List(player.recentlyPlayed) { song in
                    SongRowView(song: song, onPlay: {
                        player.play(songs: player.recentlyPlayed, startAt: player.recentlyPlayed.firstIndex(of: song) ?? 0)
                    })
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(CTColors.background(for: colorScheme))
    }
}

struct PlaylistDetailView: View {
    let playlistID: String
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    @State private var detail: PlaylistDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// 加载代次：切换歌单时 .task(id:) 只保证取消旧 Task，但旧 load() 可能已跨过 await 恢复，
    /// 继续写共享的 detail，会把上一个歌单的条目覆盖到当前歌单上。用代次令牌做提交前校验。
    @State private var loadToken = UUID()

    private let provider = NeteaseProvider.shared
    private let demoProvider = DemoProvider.shared

    /// 演示模式的歌单来自内置数据，不能打到网易云接口
    private var activeProvider: MusicProvider {
        appState.isDemoMode ? demoProvider : provider
    }

    private var tracks: [Song] { detail?.tracks ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ErrorView(message: error, retryAction: { Task { await load() } })
            } else if let detail {
                // 歌单头部
                HStack(alignment: .top, spacing: CTSpacing.lg) {
                    CoverImage(url: detail.playlist.coverURL, size: 160) {
                        RoundedRectangle(cornerRadius: CTRadius.medium)
                            .fill(CTColors.overlay(for: colorScheme))
                            .overlay(Image(systemName: "music.note.list").foregroundStyle(.secondary))
                    }
                    .frame(width: 160, height: 160)
                    .clipped()
                    .cornerRadius(CTRadius.medium)

                    VStack(alignment: .leading, spacing: CTSpacing.sm) {
                        Text(detail.playlist.name)
                            .font(CTTypography.pageTitle)
                            .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                        if let creator = detail.playlist.creatorName {
                            Text("创建者：\(creator)")
                                .font(CTTypography.caption)
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        }
                        HStack(spacing: CTSpacing.sm) {
                            Text("\(detail.totalTrackCount) 首歌曲")
                                .font(CTTypography.caption)
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            if tracks.count < detail.totalTrackCount {
                                // 分页仍在并发补齐，先给出进度避免用户以为加载卡死
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                                Text("已加载 \(tracks.count) 首")
                                    .font(CTTypography.caption)
                                    .foregroundStyle(CTColors.textSecondary(for: colorScheme).opacity(0.7))
                            }
                        }
                        Button("播放全部") {
                            player.play(songs: tracks, startAt: 0)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tracks.isEmpty)
                    }
                    Spacer()
                }
                .padding(CTSpacing.xl)

                List(tracks) { song in
                    SongRowView(song: song, onPlay: {
                        player.play(songs: tracks, startAt: tracks.firstIndex(of: song) ?? 0)
                    })
                }
            } else {
                EmptyStateView(icon: "music.note.list", title: "歌单", message: "歌单不存在")
            }
        }
        .background(CTColors.background(for: colorScheme))
        // 歌单 ID 或登录/演示状态变化时重新加载
        .task(id: "\(playlistID)-\(appState.dataContextKey)") { await load() }
    }

    private func load() async {
        guard !playlistID.isEmpty else { return }
        // 领取新代次并立即作废旧代次的所有在途写入
        let token = UUID()
        loadToken = token
        isLoading = true
        errorMessage = nil
        // 切歌单时先清空上一个歌单的内容，避免新旧混排
        detail = nil
        do {
            // 演示模式歌单来自内置数据，不涉及网易云分页与缓存
            if !appState.isDemoMode, let cached = await provider.cachedPlaylistTracks(id: playlistID) {
                var loaded = try await activeProvider.fetchPlaylistDetail(id: playlistID)
                guard loadToken == token, !Task.isCancelled else { return }
                loaded.tracks = cached
                detail = loaded
                isLoading = false
                return
            }

            // 1. 先只取详情并立即渲染（标题/封面/首屏曲目），不再等全部分页结束
            var loaded = try await activeProvider.fetchPlaylistDetail(id: playlistID)
            guard loadToken == token, !Task.isCancelled else { return }
            detail = loaded
            isLoading = false

            // 2. 其余分页并发拉取，边到边追加
            guard !appState.isDemoMode,
                  loaded.totalTrackCount > loaded.tracks.count,
                  loaded.totalTrackCount > 0 else { return }
            var accumulated = loaded.tracks
            for try await batch in await provider.streamPlaylistTracks(
                id: playlistID,
                totalCount: loaded.totalTrackCount
            ) {
                // 每个批次提交前都要校验代次：旧歌单的迟到批次必须丢弃
                guard loadToken == token, !Task.isCancelled else { return }
                accumulated.append(contentsOf: batch)
                guard var current = detail else { return }
                current.tracks = accumulated
                detail = current
            }
        } catch {
            guard loadToken == token else { return }
            errorMessage = error.localizedDescription
        }
        guard loadToken == token else { return }
        isLoading = false
    }
}
