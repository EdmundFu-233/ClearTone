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
        .overlay(alignment: .bottom) { WriteErrorToast() }
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
        List(selection: sidebarSelection) {
            Section("探索") {
                ForEach(topLevelPages(.discover, .search, .topList, .radio, .personalFM), id: \.self) { page in
                    Label(page.rawValue, systemImage: page.systemImage)
                        .tag(page)
                }
            }

            Section("资料库") {
                ForEach(topLevelPages(.myMusic, .liked, .local, .recent, .messages), id: \.self) { page in
                    Label(page.rawValue, systemImage: page.systemImage)
                        .tag(page)
                }
            }

            Section(L10n.Sidebar.playlists) {
                if appState.isLoggedIn {
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
                                appState.openPlaylist(playlist.id)
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
            VStack(spacing: 0) {
                Button { appState.switchToTopLevel(.profile) } label: {
                    Label("我的", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(CTSpacing.md)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
                Button { appState.switchToTopLevel(.settings) } label: {
                    Label("设置", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(CTSpacing.md)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(CTColors.panel(for: colorScheme))
        }
        .background(CTColors.panel(for: colorScheme))
        .task(id: appState.dataContextKey) { await appState.loadUserPlaylists() }
    }

    /// 只渲染指定的顶级栏目（保持传入顺序）。
    /// 侧栏不该出现专辑页/歌手页这类详情页 —— 它们靠返回键退出。
    private func topLevelPages(_ pages: AppState.Page...) -> [AppState.Page] {
        pages.filter { AppState.Page.sidebarPages.contains($0) }
    }

    /// 侧栏选中项。
    ///
    /// 详情页不参与选择：`List(selection:)` 只在选中值等于某行 tag 时高亮它，
    /// 详情页在栈里但不在列表里，所以不传 selection 即可避免侧栏整块失去高亮。
    private var sidebarSelection: Binding<AppState.Page?> {
        Binding(
            get: { appState.currentPage.isDetail ? nil : appState.currentPage },
            set: { newValue in
                guard let newValue else { return }
                // 侧栏是「换栏目」而非「往下钻」：清空返回栈
                appState.switchToTopLevel(newValue)
            }
        )
    }
}

// MARK: - 工具栏
struct ToolbarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: CTSpacing.md) {
            // 返回：详情页必须有退路。早期版本只有 currentPage，
            // 进了专辑/歌手/歌单详情就再也回不到列表。
            if appState.canGoBack {
                Button {
                    appState.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("返回 \(appState.pageHistory.last?.rawValue ?? "")")
                .accessibilityLabel("返回")
            }

            if appState.currentPage == .search {
                Label("搜索音乐", systemImage: "magnifyingglass")
                    .font(CTTypography.bodyMedium)
                    .foregroundStyle(.secondary)
            } else {
                SearchField()
                    .frame(maxWidth: 360)
                    .focused($isSearchFocused)
            }
            Spacer()
            // 账户头像
            AccountButton()
        }
        .padding(.horizontal, CTSpacing.lg)
        .padding(.vertical, CTSpacing.md)
        .background(CTColors.background(for: colorScheme))
        // ⌘F：切回被详情页盖住时先回顶层，否则用户看不到聚焦的输入框
        .onReceive(NotificationCenter.default.publisher(for: .cleartoneFocusSearch)) { _ in
            if appState.currentPage.isDetail { appState.goBack() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        }
    }
}

struct SearchField: View {
    @EnvironmentObject var appState: AppState

    /// 直接绑定 `appState.searchQuery`，不要用本地 @State：
    /// 本地副本与全局状态会各说各话 —— 从搜索页返回时输入框是空的，
    /// 而搜索页里还留着上次的关键词。
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索歌曲、歌手、专辑、歌单", text: $appState.searchQuery)
                .textFieldStyle(.plain)
                .onSubmit {
                    guard !appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    appState.switchToTopLevel(.search)
                }
            if !appState.searchQuery.isEmpty {
                Button(action: { appState.searchQuery = "" }) {
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
            image = await CoverLoader.shared.avatar(url: url, pointSize: size)
        }
    }
}

/// 登录弹窗在**全 App 唯一**的呈现点。
///
/// 三个触发点（头像、未登录占位、`LoginRequiredView`、会话失效）都只写
/// `appState.isLoginPresented`，由这里统一呈现。
struct AccountButton: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.isLoggedIn {
                Menu {
                    if let account = appState.account {
                        Text("\(account.nickname)\(account.isVIP ? " · VIP" : "")")
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
                Button(action: { appState.isLoginPresented = true }) {
                    AvatarView(url: appState.account?.avatarURL, size: 28)
                }
                .buttonStyle(.plain)
                .help(L10n.Common.login)
            }
        }
        .sheet(isPresented: $appState.isLoginPresented) {
            LoginView()
                .environmentObject(appState)
        }
        // 会话失效时 `AppState.handleSessionExpired` 直接置位 isLoginPresented，
        // 不再经由这里的 onChange 中转 —— 中转那一层在视图不在树里时会丢标志。
        // `needsReLogin` 不在这里复位：它只管禁用写操作，登录成功后
        // `didLogin` → `applyAccount` 会一并清掉。
    }
}

// MARK: - 全局写操作失败提示
///
/// `lastWriteError` 之前只有歌单页与「我的音乐」在读，而**心形的六个入口**
/// （播放栏、正在播放、搜索、发现、喜欢的音乐、⌘⇧D）都不读它 ——
/// 收藏失败时心形弹回去、界面一句话都没有，用户只会以为 App 卡住了。
/// 这里做成挂在窗口上的 toast，任何写失败都能被看见。
private struct WriteErrorToast: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Group {
            if let message = appState.lastWriteError {
                HStack(spacing: CTSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(CTColors.accent(for: colorScheme))
                    Text(message)
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                        .lineLimit(2)
                    Button {
                        appState.clearWriteError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                }
                .padding(CTSpacing.md)
                .ctGlassSurface()
                .frame(maxWidth: 420)
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: message) {
                    // 4 秒后自动消失。id 用 message：连续两次不同的报错
                    // 各自计时，同一条重复报错不会把计时器重置掉。
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    if appState.lastWriteError == message {
                        appState.clearWriteError()
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.lastWriteError)
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
            case .topList:
                TopListView()
            case .radio:
                RadioView()
            case .personalFM:
                PersonalFMView()
            case .myMusic:
                MyMusicView()
            case .liked:
                LikedView()
            case .local:
                LocalMusicView()
            case .recent:
                RecentView()
            case .messages:
                MessagesView()
            case .profile:
                ProfileView()
            case .playlistDetail:
                PlaylistDetailView(playlistID: appState.selectedPlaylistID ?? "")
            case .radioDetail:
                RadioDetailView(radioID: appState.selectedRadioID ?? "")
            case .albumDetail:
                AlbumDetailView(albumID: appState.selectedAlbumID ?? "")
            case .artistDetail:
                ArtistDetailView(artistID: appState.selectedArtistID ?? "")
            case .songComments:
                SongCommentsView()
            case .settings:
                SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CTColors.background(for: colorScheme))
    }
}
