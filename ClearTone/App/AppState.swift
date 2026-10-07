import Foundation
import Combine
import SwiftUI

/// 全局应用状态。
///
/// 从 `ClearToneApp.swift` 拆出，因为它原本和 macOS 的 AppDelegate 混在一个
/// 文件里，而 iOS 端不需要 AppDelegate（也用不到 NSApplication）。
/// 状态层本身是纯 ObservableObject，两个平台共享。
@MainActor
public class AppState: ObservableObject {
    @Published var currentPage: Page = .discover
    @Published var isNowPlayingExpanded: Bool = false
    @Published var showQueue: Bool = false
    @Published public private(set) var account: AccountInfo?
    @Published public private(set) var isLoggedIn: Bool = false
    @Published var selectedPlaylistID: String?
    /// 当前打开的电台 id
    @Published var selectedRadioID: String?
    /// 当前打开的专辑 id（专辑详情页）
    @Published var selectedAlbumID: String?
    /// 当前打开的歌手 id（歌手详情页）
    @Published var selectedArtistID: String?
    /// 当前查看评论的歌曲（评论页）
    @Published var commentSong: Song?
    @Published var searchQuery = ""

    /// 导航历史栈（不含当前页）。详情页是从列表点进来的，
    /// 没有它就无法「返回」—— 之前的版本只有 currentPage，
    /// 进了专辑/歌手/歌单详情就再也回不去列表。
    @Published private(set) var pageHistory: [Page] = []

    /// 当前页的上一级。侧栏点选**替换**栈（用户是在换栏目，不是往下钻），
    /// 详情页导航**压栈**。
    var canGoBack: Bool { !pageHistory.isEmpty }

    func goBack() {
        guard let previous = pageHistory.popLast() else { return }
        currentPage = previous
    }

    /// 切换到某个顶级栏目：清空返回栈。
    /// 用户是在「换栏目」而不是「往下钻」，栈不该留着上一个栏目的路径。
    func switchToTopLevel(_ page: Page) {
        pageHistory.removeAll()
        currentPage = page
    }

    /// 从列表进入详情：压栈，可返回
    func navigateToDetail(_ page: Page) {
        guard page != currentPage else { return }
        // 连续压同一个详情页没有意义（用户反复点同一个卡片）
        guard pageHistory.last != page else {
            currentPage = page
            return
        }
        pageHistory.append(currentPage)
        currentPage = page
    }

    /// 从搜索/推荐结果跳转到另一个详情：栈里已有的详情要被替换掉，
    /// 否则会出现「专辑 → 歌手 → 返回又回到专辑」的回环

    func openPlaylist(_ id: String) {
        selectedPlaylistID = id
        navigateToDetail(.playlistDetail)
    }

    func openRadio(_ id: String) {
        selectedRadioID = id
        navigateToDetail(.radioDetail)
    }

    func openAlbum(_ id: String) {
        selectedAlbumID = id
        navigateToDetail(.albumDetail)
    }

    func openArtist(_ id: String) {
        selectedArtistID = id
        navigateToDetail(.artistDetail)
    }

    func openComments(for song: Song) {
        commentSong = song
        navigateToDetail(.songComments)
    }

    /// 喜欢的歌曲（本地缓存 + 服务端同步）
    @Published public private(set) var likedSongs: [Song] = []
    /// 收藏状态版本号：每次变化自增，驱动依赖视图刷新
    @Published public private(set) var likesVersion: Int = 0

    /// 用户歌单。
    ///
    /// 原先 `SidebarView` 与 `MyMusicView` 各自持有一份并各自读/写同一个
    /// 缓存 key：同一份数据被解码两次、写两次，两处可能显示不同内容
    /// （一方失败回退缓存、一方拿到新数据）。这里作为唯一 owner。
    @Published public private(set) var userPlaylists: [Playlist] = []
    @Published public private(set) var isLoadingUserPlaylists = false
    /// 加载代次：切换账号时旧请求不得写入
    private var userPlaylistsToken = UUID()
    /// 会话失效后置位，**写操作**据此禁用（`canPerformWrite`）。
    /// 注意它不再负责弹登录 —— 那件事走 `isLoginPresented`。
    @Published var needsReLogin = false

    /// 登录弹窗。标志放在这里而不是各宿主的 `@State`：
    /// 触发点有三个（工具栏头像、内容区的「扫码登录」、会话失效自动弹），
    /// 而呈现点只有一个（工具栏 `AccountButton`）。原先每个触发点各存一份
    /// `showLogin`，于是「会话失效」那一路只能靠 `AccountButton` 自己的
    /// `onChange` 消费 —— 那个视图一旦不在树里，标志就被静默丢弃，
    /// 用户看到的是所有写操作变灰却没有任何登录提示。
    @Published var isLoginPresented = false

    /// **全量**喜欢歌曲 id，仅用于判断心形状态。
    ///
    /// 必须与 likedSongs 分开维护：likedSongs 是「前若干首」的详情列表，
    /// 早期两者都由 likedSongs 推导，导致 2808 首收藏里只有前 500 首能正确判断
    /// 收藏状态，其余 2308 首永远显示未收藏。
    private var likedIDs: Set<String> = []
    private var hasLoadedLikes = false
    /// 详情列表是否加载完成。与 `hasLoadedLikes`（id 集合，心形状态）分开：
    /// id 到位但详情失败时，心形已经可用，详情列表还得能重试 ——
    /// 早期共用一个标志，`fetchLikedSongs` 一次失败就让详情列表整场会话不再刷新。
    private var hasLoadedLikedSongs = false
    private let provider: MusicProvider
    /// 会话闸门与账号缓存的复位。这两个是**网易云专属**的内存副作用，
    /// 不放进 `MusicProvider`：一是本地/桩实现根本没这两样东西，
    /// 二是同名要求会和 `NeteaseProvider` 自己的 actor-isolated 方法抢名字 ——
    /// actor 内部原本同步的 `clearCache()` 会被解析成 async 版本而编译失败。
    /// 它们都离线安全（只动内存字典与计数器），单测里跑真的也无妨。
    private let sessionOwner: NeteaseProvider
    private var sessionExpiryObserver: NSObjectProtocol?

    /// 账号或会话代次变化都要刷新页面；两个已登录账号不能共用同一个标识。
    public var dataContextKey: String { "\(isLoggedIn)-\(account?.userID ?? "guest")-\(accountGeneration)" }

    /// - Parameter provider: 注入点。生产用 `NeteaseProvider.shared`；单测用桩 ——
    ///   「登录之后到底有没有去拉喜欢的音乐和用户歌单」这条曾经只在 iOS 实机上才看得出来。
    public init(provider: MusicProvider = NeteaseProvider.shared) {
        self.provider = provider
        self.sessionOwner = NeteaseProvider.shared
        // 磁盘缓存的读取不在这里做：@StateObject 的初值在首帧前求值，
        // 上千首 likedSongs 的 JSON 解码会造成启动停顿。改由 restoreLoginState()
        // 在 onAppear 后异步填充（那里本来就有一处相同的读取，顺手合并）。
        // 任意请求触发会话失效时，统一清理登录态并提示重新登录
        sessionExpiryObserver = NotificationCenter.default.addObserver(
            forName: .clearToneSessionExpired, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSessionExpired() }
        }
    }

    private func handleSessionExpired() {
        guard isLoggedIn || account != nil else { return }
        CTLog.security.warning("登录状态已失效，请重新登录")
        // **只清身份，不清用户数据。** 早期这里传的是 clearLikedCache: true，
        // 于是「网易云一次风控拒绝 → 弹扫码」会把本地红心（2808 首）与
        // 歌单缓存一起删掉。用户重新扫码后这些数据要重新拉几百个请求。
        // 真掉线也不该删 —— 缓存只是「可能过期」，重新登录后会被覆盖。
        clearSession(clearLikedCache: false)
        needsReLogin = true
        isLoginPresented = true
    }

    // MARK: - 登录态

    /// 启动时恢复登录态：有 cookie 时先用缓存立即恢复，再后台校验
    func restoreLoginState() async {
        guard !isLoggedIn else { return }
        // 磁盘缓存统一在这里读一次：原先 init 与此处各读一遍（重复解码上千首 likedSongs）
        if account == nil {
            account = PersistenceStore.shared.loadCachedAccount()
        }
        // 缓存账号里就有 isVIP，先用它把音质解析对。
        // 否则冷启动的第一首歌会按「非 VIP → 极高」拉流，
        // 等 /user/account 回来再切成无损，用户听到的是先差后好的一小段。
        PlayerController.shared.setAccountIsVIP(account?.isVIP ?? false)
        if likedSongs.isEmpty {
            let cachedSongs = PersistenceStore.shared.loadCachedLikedSongs()
            // 优先用全量 id 缓存；没有（旧版本遗留）才从列表推导
            let cachedIDs = PersistenceStore.shared.loadCachedLikedSongIDs()
            applyLikedSongs(cachedSongs, ids: cachedIDs.isEmpty ? nil : cachedIDs)
        }

        let cookie = try? NeteaseProvider.loadLoginCookie()
        guard let cookie, !cookie.isEmpty else {
            // 无 cookie：清理可能残留的缓存登录态
            clearSession(clearLikedCache: false)
            return
        }

        if account != nil {
            isLoggedIn = true
        }

        do {
            if let info = try await provider.fetchAccountInfo() {
                applyAccount(info)
            } else {
                clearSession(clearLikedCache: true)
                return
            }
        } catch {
            // 网络失败时保留缓存登录态供离线使用；无缓存则视为未登录
            CTLog.security.warning("恢复登录态失败: \(CTLog.sanitize(error.localizedDescription))")
            if account == nil { isLoggedIn = false }
        }

        if isLoggedIn {
            // 与 `didLogin` 对齐：冷启动也要把用户歌单拉上。
            // 「添加到歌单」子菜单（`IOSRootView` 的行菜单）读的是 `userPlaylists`，
            // 而加载点原先挂在资料库 tab 的 `.task` 上 —— 冷启动后不点资料库就直接用它，
            // 菜单恒为空、且没有任何 loading 提示。
            await loadLikedSongs(force: true)
            await loadUserPlaylists()
        }
    }

    /// 登录成功（供登录流程调用）
    func didLogin(account info: AccountInfo) {
        applyAccount(info)
        // 串起来跑，不能各开各的 Task：
        // ① 必须先 `clearCache()` 再拉数据，否则上一个账号的响应缓存会被这次加载命中；
        // ② 资料库（喜欢的音乐 + 用户歌单）原先只有**冷启动**的 `restoreLoginState`
        //    和 macOS 侧 `LoginView` 里的那句 `await loadLikedSongs` 会拉 ——
        //    应用内登录（扫码 / Cookie）在 iOS 上什么都不加载。于是「喜欢的音乐」
        //    显示 0 首、全站红心全是未收藏，「添加到歌单」子菜单在点开资料库 tab
        //    之前恒为空（读取点在 `IOSRootView` 的菜单里，加载点却挂在资料库 tab 上）。
        //    放进这里一处覆盖两个平台，视图一行都不用加。
        Task {
            await sessionOwner.clearCache()
            await sessionOwner.resetSessionGuard()
            await loadLikedSongs(force: true)
            await loadUserPlaylists()
        }
    }

    /// 退出登录：清除服务端会话与本地缓存
    func performLogout() async {
        try? await provider.logout()
        await sessionOwner.clearCache()
        clearSession(clearLikedCache: true)
    }

    private func applyAccount(_ info: AccountInfo) {
        account = info
        isLoggedIn = true
        accountGeneration += 1
        // 会话失效后重新登录成功，必须把 `needsReLogin` 放下来。
        //
        // `handleSessionExpired` 会置位它来禁用写操作，但**没有任何地方复位**：
        // 用户重新登录（`didLogin` → `applyAccount`）后 `isLoggedIn` 已经是 true，
        // 而 `canPerformWrite` 仍是 `true && !true == false`。于是 iOS 上点心形
        // 走的是「未登录」分支 —— 每次都把登录弹窗再弹一遍，看起来像点了没反应；
        // 「添加到歌单」子菜单也整块消失。重启 App 才会好，所以真机上极难定位。
        needsReLogin = false
        // 音质偏好为「自动」时，实际档位按 VIP 解析（VIP → 无损）。
        // 必须在这里同步：账号是**异步**确认的，比 PlayerController.init 晚，
        // 只在 init 里解析的话，登录后永远停在「极高」。
        PlayerController.shared.setAccountIsVIP(info.isVIP)
        // **每次确认账号都要回写 userID**，不只是在扫码成功时。
        //
        // `/likelist`、`/user/playlist`、`/album/sublist`、`/artist/sublist`、
        // `/user/record`、`/msg/comments` 全都靠它拼 uid。
        // 早期只有 LoginView 在扫码成功后写一次，于是：
        // 恢复登录态的路径（restoreLoginState → applyAccount）从不刷新，
        // 一旦存的值过期或写错（比如早期版本从别的字段取值），
        // 这 6 个接口会**静默**返回空 / 报错，而界面上看不出是 uid 的问题
        // （实测就踩到过：存的是 501，真实是 86080189，
        //   /user/record 直接 502、/msg/comments 报「userId 与当前登录用户不匹配」）。
        try? KeychainStore.shared.save(info.userID, for: .neteaseUserID)
        PersistenceStore.shared.saveCachedAccount(info)
    }

    private func clearSession(clearLikedCache: Bool) {
        account = nil
        isLoggedIn = false
        // 冷却是**按账号**的：退登后新账号不该继承上一个账号的限流倒计时
        likeWriteCooldownUntil = nil
        likesWriteError = nil
        likeRequestsInFlight.removeAll()
        // 掉登录 = 不是 VIP 了，「自动」档位要跟着回落。
        // 不复位的话退登后仍在按无损请求，白白拿 403。
        PlayerController.shared.setAccountIsVIP(false)
        hasLoadedLikes = false
        hasLoadedLikedSongs = false
        likedIDs = []
        likedSongs = []
        likesVersion += 1
        // 关键：让所有在途的用户数据请求作废
        accountGeneration += 1
        userPlaylistsToken = UUID()
        // 内存里的歌单也要清。它原先只清磁盘缓存（`clearLikedCache` 那支），
        // 于是「A 退出 → B 登录 → B 拉歌单失败」时，资料库会把 **A 的歌单**
        // 挂在 B 的账号下显示，点进去加载的也是 A 的歌单。
        // 在途请求靠上面的 token 作废，所以这里直接清空不会被迟到的响应写回来。
        userPlaylists = []
        isLoadingUserPlaylists = false
        // 注意这里**不动 pageHistory**：掉线与「用户在哪一页」无关，
        // 重置导航栈会把用户从详情页里踹出来，重新登录后还要再点回去。
        PersistenceStore.shared.clearCachedAccount()
        if clearLikedCache {
            PersistenceStore.shared.clearCachedLikedSongs()
            PersistenceStore.shared.clearCachedUserPlaylists()
        }
    }

    // MARK: - 社交能力入口

    /// 在线社交能力。只有真实网易云 Provider 有；本地 Provider 没有。
    var social: NeteaseProvider { NeteaseProvider.shared }

    /// 写操作是否可用（未登录 / 会话失效一律不可用）
    var canPerformWrite: Bool { isLoggedIn && !needsReLogin }

    // MARK: - 歌单写操作

    /// 新建歌单，成功后插入列表头部并打开它
    @discardableResult
    func createPlaylist(name: String, isPrivate: Bool) async -> Playlist? {
        guard canPerformWrite else { return nil }
        do {
            let created = try await social.createPlaylist(name: name, isPrivate: isPrivate)
            userPlaylists.insert(created, at: 0)
            PersistenceStore.shared.saveCachedUserPlaylists(userPlaylists)
            return created
        } catch {
            CTLog.general.error("创建歌单失败: \(CTLog.sanitize(error.localizedDescription))")
            lastWriteError = error.ctUserMessage
            return nil
        }
    }

    /// 删除歌单（仅限自己创建的）
    func deletePlaylist(_ playlist: Playlist) async -> Bool {
        guard canPerformWrite else { return false }
        do {
            try await social.deletePlaylist(id: playlist.id)
            userPlaylists.removeAll { $0.id == playlist.id }
            PersistenceStore.shared.saveCachedUserPlaylists(userPlaylists)
            // 正在看被删的歌单就退回列表
            if selectedPlaylistID == playlist.id { currentPage = .myMusic }
            return true
        } catch {
            CTLog.general.error("删除歌单失败: \(CTLog.sanitize(error.localizedDescription))")
            lastWriteError = error.ctUserMessage
            return false
        }
    }

    func renamePlaylist(_ playlist: Playlist, to name: String) async -> Bool {
        guard canPerformWrite else { return false }
        do {
            try await social.updatePlaylistName(id: playlist.id, name: name)
            if let index = userPlaylists.firstIndex(where: { $0.id == playlist.id }) {
                userPlaylists[index].name = name
            }
            PersistenceStore.shared.saveCachedUserPlaylists(userPlaylists)
            return true
        } catch {
            CTLog.general.error("重命名歌单失败: \(CTLog.sanitize(error.localizedDescription))")
            lastWriteError = error.ctUserMessage
            return false
        }
    }

    /// 加歌到歌单 / 从歌单移除
    ///
    /// 成功后必须让歌单曲目缓存失效，否则用户会看到「加了但歌单没变」
    /// —— `PlaylistDetailView` 优先读 `cachedPlaylistTracks`。
    func modifyPlaylist(_ playlist: Playlist, songIDs: [String], add: Bool) async -> Bool {
        guard canPerformWrite, !songIDs.isEmpty else { return false }
        do {
            if add {
                try await social.addSongsToPlaylist(playlistID: playlist.id, songIDs: songIDs)
            } else {
                try await social.removeSongsFromPlaylist(playlistID: playlist.id, songIDs: songIDs)
            }
            await social.clearCache()
            if let index = userPlaylists.firstIndex(where: { $0.id == playlist.id }) {
                userPlaylists[index].trackCount = max(0, userPlaylists[index].trackCount + (add ? songIDs.count : -songIDs.count))
                // 与 create/delete/rename 一致：改了就要落盘，否则加删歌后
                // 在下次整表刷新前重启，曲目数会退回旧值。
                PersistenceStore.shared.saveCachedUserPlaylists(userPlaylists)
            }
            return true
        } catch {
            CTLog.general.error("\(add ? "添加" : "移除")歌曲失败: \(CTLog.sanitize(error.localizedDescription))")
            lastWriteError = error.ctUserMessage
            return false
        }
    }

    /// 最近一次写操作的错误信息，供 UI 展示
    @Published var lastWriteError: String?
    func clearWriteError() { lastWriteError = nil }

    /// 把任意错误转成写操作提示。
    ///
    /// 视图层原先只有 `createPlaylist` / `deletePlaylist` 那几条路径会设
    /// `lastWriteError`，其余写操作失败只进日志 —— 界面上一点反馈都没有。
    /// 详情页（歌手关注、评论点赞…）现在统一走这里。
    func publishWriteError(_ error: Error) {
        CTLog.general.error("写操作失败: \(CTLog.sanitize(error.localizedDescription))")
        lastWriteError = error.ctUserMessage
    }

    // MARK: - 收藏

    func isLiked(_ songID: String) -> Bool { likedIDs.contains(songID) }

    func loadLikedSongs(force: Bool = false) async {
        guard isLoggedIn else { return }
        if hasLoadedLikes && hasLoadedLikedSongs && !force { return }
        // 账号代次：切换账号/退出会自增。await 之后必须比对，
        // 否则「A 账号请求在途 → 退出 → B 账号登录 → A 的响应回来」
        // 会把 A 的收藏写进 B 的界面，并污染磁盘缓存。
        let generation = accountGeneration
        let dataContext = dataContextKey
        do {
            // 先取全量 id（约 60KB）—— 心形状态靠它判断，必须完整
            let ids = try await provider.fetchLikedSongIDs()
            guard generation == accountGeneration, dataContext == dataContextKey else { return }
            applyLikedSongs(PersistenceStore.shared.loadCachedLikedSongs(), ids: ids)
            PersistenceStore.shared.saveCachedLikedSongIDs(ids)
            hasLoadedLikes = true

            // 详情列表随后加载，不阻塞心形状态
            let songs = try await provider.fetchLikedSongs()
            guard generation == accountGeneration, dataContext == dataContextKey else { return }
            applyLikedSongs(songs, ids: ids)
            PersistenceStore.shared.saveCachedLikedSongs(songs)
            hasLoadedLikedSongs = true
        } catch {
            CTLog.general.error("加载喜欢的歌曲失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }

    /// 账号代次计数器。任何会改变「当前是谁」的操作都要让它自增。
    private var accountGeneration = 0
    /// 当前账号代次的快照
    var currentAccountGeneration: Int { accountGeneration }

    /// 加载用户歌单（侧栏与「我的音乐」共用这一个数据源）。
    ///
    /// 先用本地缓存立即填充避免空白，再拉网络。带代次令牌，
    /// 切换账号后旧请求返回会被丢弃，不会串号。
    func loadUserPlaylists() async {
        let token = UUID()
        userPlaylistsToken = token
        let generation = accountGeneration
        guard isLoggedIn else {
            userPlaylists = []
            return
        }
        if userPlaylists.isEmpty {
            let cached = PersistenceStore.shared.loadCachedUserPlaylists()
            guard userPlaylistsToken == token, !Task.isCancelled else { return }
            userPlaylists = cached
        }
        isLoadingUserPlaylists = userPlaylists.isEmpty
        // 用 defer 复位：成功路径会在代次/取消校验失败时提前 return，
        // 卡住的话空歌单账号的侧栏会一直转圈（其它 session 都靠 defer 兜底）。
        defer { if userPlaylistsToken == token { isLoadingUserPlaylists = false } }
        do {
            let loaded = try await provider.fetchUserPlaylists()
            guard userPlaylistsToken == token, generation == accountGeneration,
                  !Task.isCancelled else { return }
            userPlaylists = loaded
            PersistenceStore.shared.saveCachedUserPlaylists(loaded)
        } catch {
            guard userPlaylistsToken == token else { return }
            // 失败时保留缓存内容，避免侧栏闪空
            CTLog.general.error("加载歌单失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }

    /// 切换收藏状态（乐观更新，失败回滚）。返回切换后的状态。
    ///
    /// 关键：收藏状态只增删**单个 id**，绝不能拿 likedSongs 重建 likedIDs。
    /// 早期版本用 `applyLikedSongs(optimistic)` 顺带重建 likedIDs，
    /// 而 likedSongs 只是一份详情列表，重建会把 likedIDs 压缩成列表的规模 ——
    /// 用户有 2808 首收藏时 likedIDs 只剩几百项，于是排在列表之外的歌
    /// 点心形「看起来没反应」，因为下一次 isLiked 仍然返回 false。
    ///
    /// ## 为什么要有在途锁与冷却
    ///
    /// 这两条不是锦上添花，而是**防止把风控越点越死**的护栏。
    ///
    /// 实测：账号一旦触发网易云的写接口限流，所有写接口会一起挂 ——
    /// `/like` 回 `524 当前环境异常`，连 `/playlist/subscribe` 都回
    /// `405 操作过于频繁`（同一个账号、同一时刻、读接口全 200）。
    /// 而原实现对心形点击**没有任何在途保护**：一次点击一个 Task，
    /// 连点 10 次就是 10 个并发写请求，每次失败都让限流窗口**继续延长**。
    ///
    /// 所以：同一首歌有请求在途时直接忽略连点；遇到 405/524 这类
    /// 「服务端让我们别再试」的拒绝时进入冷却，期间连点击都不发出去。
    @discardableResult
    func toggleLike(_ song: Song) async -> Bool {
        guard song.source == .netease, isLoggedIn else { return false }
        // 冷却中：连请求都不发。用户看到的仍是心形，但 tooltip 说明为什么点不动。
        guard !isLikeWriteCoolingDown else { return likedIDs.contains(song.id) }
        // 在途：忽略连点，否则一次误操作会并发发好几个写请求
        guard !likeRequestsInFlight.contains(song.id) else { return likedIDs.contains(song.id) }
        likeRequestsInFlight.insert(song.id)
        defer { likeRequestsInFlight.remove(song.id) }

        let wasLiked = likedIDs.contains(song.id)

        // 乐观更新：状态集合增删单首，列表同步增删该曲
        updateLikedID(song.id, isLiked: !wasLiked)
        var optimistic = likedSongs.filter { $0.id != song.id }
        if !wasLiked { optimistic.insert(song, at: 0) }
        likedSongs = optimistic

        do {
            try await provider.likeSong(id: song.id, like: !wasLiked)
            PersistenceStore.shared.saveCachedLikedSongIDs(Array(likedIDs))
            PersistenceStore.shared.saveCachedLikedSongs(likedSongs)
            likesWriteError = nil
            return !wasLiked
        } catch {
            CTLog.general.error("收藏操作失败: \(CTLog.sanitize(error.localizedDescription))")
            // 只回滚**这一首**。早期把整份 likedIDs/likedSongs 快照下来、失败时整体
            // 还原：用户很快点了两个心形时，A 失败会把 B 已经成功的收藏一起抹掉，
            // 并把旧值写回磁盘 —— 服务端认为 B 已收藏，本地却显示未收藏。
            updateLikedID(song.id, isLiked: wasLiked)
            var reverted = likedSongs.filter { $0.id != song.id }
            if wasLiked { reverted.insert(song, at: 0) }
            likedSongs = reverted
            PersistenceStore.shared.saveCachedLikedSongIDs(Array(likedIDs))
            PersistenceStore.shared.saveCachedLikedSongs(likedSongs)
            // 失败必须让用户看见。原来只写日志，界面表现是「心形弹回去、
            // 什么都不说」，用户只会以为 App 卡了。
            lastWriteError = error.ctUserMessage
            if Self.isWriteThrottled(error) {
                // 服务端明说「别再试」（405/524）。进入冷却，
                // 否则用户的下一次点击又是一次被拒的写请求，只会让窗口更长。
                enterLikeWriteCooldown(for: error)
            }
            return wasLiked
        }
    }

    // MARK: - 收藏写操作的限流护栏

    /// 正在发请求的歌曲。用来挡住连点。
    private var likeRequestsInFlight: Set<String> = []
    /// 冷却截止时间。服务端说「操作过于频繁」之后的这段时间内不再发写请求。
    private var likeWriteCooldownUntil: Date?
    /// 收藏失败的原因（供心形 tooltip 解释「为什么点不动」）
    @Published private(set) var likesWriteError: String?

    /// 冷却时长（秒）。取 30 是权衡：太短用户会觉得「还是不行」而继续点
    /// （更糟），太长则一次偶发失败要干等。30 秒足以让多数限流窗口过去，
    /// 也短到不会让人以为 App 坏了。
    ///
    /// 非 private：`NeteaseProvider.likeFailureMessage` 要在提示文案里引用它，
    /// 免得「提示里写 30 秒」与「实际冷却 30 秒」分家。
    ///
    /// `nonisolated`：这是个纯常量，而 `AppState` 整体是 `@MainActor` 的，
    /// provider 那边是 `nonisolated static` 函数 —— 不加这个修饰符
    /// 编译器会拒绝跨隔离引用（哪怕它只是只读 Int）。
    nonisolated static let likeWriteCooldownSeconds: Int = 30
    private static let likeWriteCooldown: TimeInterval = TimeInterval(likeWriteCooldownSeconds)

    /// 冷却剩余秒数（UI 用；0 表示不在冷却中）
    var likeCooldownRemaining: Int {
        guard let until = likeWriteCooldownUntil else { return 0 }
        let remaining = until.timeIntervalSinceNow
        return remaining > 0 ? Int(remaining.rounded(.up)) : 0
    }

    var isLikeWriteCoolingDown: Bool { likeCooldownRemaining > 0 }

    private func enterLikeWriteCooldown(for error: Error) {
        likeWriteCooldownUntil = Date().addingTimeInterval(Self.likeWriteCooldown)
        likesWriteError = (error as? MusicError)?.ctUserMessage ?? error.ctUserMessage
    }

    /// 判断这是不是「服务端让我们别再试」这类拒绝。
    ///
    /// 405 = 操作过于频繁，524 = 当前环境异常（风控）。两者都是
    /// **限流**而非「请求写错了」—— 重试只会延长窗口，所以要冷却。
    /// 其余错误（如 404 歌曲不存在）重试是有意义的，不该冷却。
    static func isWriteThrottled(_ error: Error) -> Bool {
        guard let musicError = error as? MusicError else { return false }
        switch musicError {
        case .apiError(let code, _):
            return code == 405 || code == 524
        case .rateLimited:
            return true
        default:
            return false
        }
    }

    /// 应用完整收藏数据：id 集合与详情列表一起更新
    private func applyLikedSongs(_ songs: [Song], ids: [String]? = nil) {
        likedSongs = songs
        // 传入了权威 id 就用它；否则从当前列表推导（仅用于本地缓存这种
        // 「只有列表没有 id」的场景）
        likedIDs = ids.map(Set.init) ?? Set(songs.map(\.id))
        likesVersion += 1
    }

    /// 单独更新收藏状态集合（列表不变），用于增删单首的场景
    private func updateLikedID(_ songID: String, isLiked: Bool) {
        if isLiked {
            likedIDs.insert(songID)
        } else {
            likedIDs.remove(songID)
        }
        likesVersion += 1
    }

    public enum Page: String, CaseIterable, Sendable {
        case discover = "发现音乐"
        case search = "搜索"
        case topList = "排行榜"
        case radio = "电台"
        case personalFM = "私人FM"
        case myMusic = "我的音乐"
        case liked = "喜欢的音乐"
        case local = "本地音乐"
        case recent = "最近播放"
        case messages = "消息"
        case profile = "我的"
        case playlistDetail = "歌单详情"
        case radioDetail = "电台详情"
        case albumDetail = "专辑详情"
        case artistDetail = "歌手详情"
        case songComments = "歌曲评论"
        case settings = "设置"

        /// 侧栏里出现的顶级栏目。详情页不出现在侧栏，只靠返回键退出。
        static var sidebarPages: [Page] {
            [.discover, .search, .topList, .radio, .personalFM,
             .myMusic, .liked, .local, .recent, .messages]
        }

        /// 需要压入导航栈的详情页
        var isDetail: Bool { Page.detailPages.contains(self) }

        private static let detailPages: Set<Page> = [
            .playlistDetail, .radioDetail, .albumDetail, .artistDetail, .songComments,
        ]

        var systemImage: String {
            switch self {
            case .discover: return "music.note.house"
            case .search: return "magnifyingglass"
            case .topList: return "list.number"
            case .radio: return "dot.radiowaves.left.and.right"
            case .personalFM: return "waveform.badge.magnifyingglass"
            case .myMusic: return "music.note.list"
            case .liked: return "heart"
            case .local: return "folder"
            case .recent: return "clock"
            case .messages: return "bell"
            case .profile: return "person.crop.circle"
            case .playlistDetail: return "music.note.list"
            case .radioDetail: return "dot.radiowaves.left.and.right"
            case .albumDetail: return "square.stack"
            case .artistDetail: return "person.wave.2"
            case .songComments: return "text.bubble"
            case .settings: return "gearshape"
            }
        }
    }
}
