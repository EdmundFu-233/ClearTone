import XCTest

/// 登录之后必须把资料库数据拉起来。
///
/// ## 为什么之前测不到
///
/// `AppState.didLogin` 原先只 `applyAccount` + 清缓存，**一条数据都不加载**：
/// - 喜欢的音乐只有**冷启动**的 `restoreLoginState` 与 macOS `LoginView` 里那句
///   `await loadLikedSongs` 会拉；
/// - 用户歌单的唯一加载点挂在「资料库」tab 的 `.task(id:)` 上，而读取点
///   （行菜单里的「添加到歌单」子菜单）在 `IOSRootView`，与 tab 无关。
///
/// 于是 iOS 上扫码登录成功后：红心全是未收藏、「添加到歌单」子菜单恒为空，
/// 而且**没有任何 loading 提示** —— 看起来就像功能不存在。
///
/// 修法是把两件加载串进 `didLogin`，两个平台一处覆盖。这条测试锁住
/// 「调用时机」，不联网、不写真实用户状态（持久化被 `run-tests.sh` 重定向）。
@MainActor
final class AppStateLoginLoadTests: XCTestCase {

    // MARK: - 桩 Provider

    /// 用 actor 而不是 `NSLock`：后者在 Swift 6 下不能出现在 async 上下文里，
    /// 而这些计数器恰恰是在 async 方法里递增的。
    private actor RecordingProvider: MusicProvider {
        let identifier = "stub"
        let displayName = "桩"

        private(set) var likedIDCalls = 0
        private(set) var likedSongCalls = 0
        private(set) var playlistCalls = 0
        private(set) var accountCalls = 0

        /// 恢复登录态时返回的账号；nil 表示「没有登录态」
        private let accountToReturn: AccountInfo?

        /// 让指定 id 的 likeSong 挂起（直到 releaseLike），以及哪些 id 要抛限流错误。
        /// 用来构造「A 的写请求还在途时 B 已经成功」这种并发时序。
        private let holdLikeIDs: Set<String>
        private let failLikeIDs: Set<String>
        private var likeWaiters: [String: CheckedContinuation<Void, Never>] = [:]
        private var releasedLikeIDs: Set<String> = []

        /// 歌单列表拉取总是失败（用来验证「新账号拉取失败时看不到上一个账号的磁盘缓存」）
        private let failUserPlaylists: Bool

        /// 首次 fetchLikedSongs 抛错，用来验证「详情失败后仍能重试」
        private var failFirstLikedSongsFetch: Bool
        private let holdLikedDetails: Bool
        private var likedDetailsWaiter: CheckedContinuation<Void, Never>?
        private var releasedLikedDetails = false

        func isLikedDetailsHeld() -> Bool { likedDetailsWaiter != nil }
        func releaseLikedDetails() {
            releasedLikedDetails = true
            likedDetailsWaiter?.resume()
            likedDetailsWaiter = nil
        }

        /// 让 fetchAccountInfo 挂起：构造「账号确认在途时退出/换号」的时序
        private let holdAccountInfo: Bool
        private var accountInfoWaiter: CheckedContinuation<Void, Never>?
        private var releasedAccountInfo = false

        func isAccountInfoHeld() -> Bool { accountInfoWaiter != nil }
        func releaseAccountInfo() {
            releasedAccountInfo = true
            accountInfoWaiter?.resume()
            accountInfoWaiter = nil
        }

        init(accountToReturn: AccountInfo? = nil,
             holdLikeIDs: Set<String> = [],
             failLikeIDs: Set<String> = [],
             failFirstLikedSongsFetch: Bool = false,
             holdLikedDetails: Bool = false,
             holdAccountInfo: Bool = false,
             failUserPlaylists: Bool = false) {
            self.accountToReturn = accountToReturn
            self.holdLikeIDs = holdLikeIDs
            self.failLikeIDs = failLikeIDs
            self.failFirstLikedSongsFetch = failFirstLikedSongsFetch
            self.holdLikedDetails = holdLikedDetails
            self.holdAccountInfo = holdAccountInfo
            self.failUserPlaylists = failUserPlaylists
        }

        func isLikeHeld(_ id: String) -> Bool { likeWaiters[id] != nil }

        func releaseLike(_ id: String) {
            releasedLikeIDs.insert(id)
            likeWaiters[id]?.resume()
            likeWaiters[id] = nil
        }

        func fetchQRCodeKey() async throws -> String { "" }
        func fetchQRCodeImage(key: String) async throws -> URL {
            URL(string: "https://example.invalid/qr")!
        }
        func checkQRCodeStatus(key: String) async throws -> QRLoginStatus { .waitingScan }
        func logout() async throws {}
        func fetchAccountInfo() async throws -> AccountInfo? {
            accountCalls += 1
            if holdAccountInfo, !releasedAccountInfo {
                await withCheckedContinuation { accountInfoWaiter = $0 }
            }
            return accountToReturn
        }

        func search(query: String, type: SearchType, page: Int, limit: Int) async throws -> SearchResult {
            SearchResult()
        }
        func fetchPlaylistDetail(id: String) async throws -> PlaylistDetail {
            PlaylistDetail(playlist: Playlist(id: id, name: "", source: .netease), tracks: [], totalTrackCount: 0)
        }
        func fetchPlaylistTracks(id: String, page: Int, limit: Int) async throws -> [Song] { [] }
        func fetchAlbumDetail(id: String) async throws -> PlaylistDetail {
            PlaylistDetail(playlist: Playlist(id: "a", name: "", source: .netease), tracks: [], totalTrackCount: 0)
        }
        func fetchArtistDetail(id: String) async throws -> ArtistDetail {
            ArtistDetail(artist: Artist(id: "r", name: ""), hotSongs: [], albums: [])
        }
        func fetchPlayableURL(songID: String, quality: AudioQuality.QualityLevel) async throws -> PlayableURL {
            throw MusicError.noPlayableURL
        }
        func fetchLyrics(songID: String) async throws -> LyricResult {
            LyricResult(lines: [], hasWordTiming: false, isPureMusic: true)
        }
        func fetchUserPlaylists() async throws -> [Playlist] {
            playlistCalls += 1
            if failUserPlaylists { throw MusicError.networkUnavailable }
            return [Playlist(id: "p1", name: "我喜欢的音乐", source: .netease)]
        }
        func fetchLikedSongs() async throws -> [Song] {
            likedSongCalls += 1
            if holdLikedDetails, !releasedLikedDetails {
                await withCheckedContinuation { likedDetailsWaiter = $0 }
            }
            if failFirstLikedSongsFetch {
                failFirstLikedSongsFetch = false
                throw MusicError.networkUnavailable
            }
            return [Song(id: "s1", title: "歌", artists: [], source: .netease)]
        }
        func fetchLikedSongIDs() async throws -> [String] {
            likedIDCalls += 1
            return ["s1"]
        }
        func likeSong(id: String, like: Bool) async throws {
            if holdLikeIDs.contains(id), !releasedLikeIDs.contains(id) {
                await withCheckedContinuation { likeWaiters[id] = $0 }
            }
            if failLikeIDs.contains(id) {
                throw MusicError.apiError(code: 524, message: "风控")
            }
        }
        func fetchRecommendPlaylists() async throws -> [Playlist] { [] }
        func fetchDailyRecommendSongs() async throws -> [Song] { [] }
    }

    // MARK: - 工具

    /// `didLogin` 里的加载是 fire-and-forget 的 Task，只能轮询等到它真的跑完。
    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 2,
        condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待\(label)超时")
    }

    // MARK: - 用例

    /// 应用内登录成功后，喜欢的音乐与用户歌单都必须被拉起。
    func testDidLoginLoadsLibraryData() async {
        let provider = RecordingProvider()
        let state = AppState(provider: provider)
        let account = AccountInfo(userID: "86080189", nickname: "测试")

        state.didLogin(account: account)

        XCTAssertTrue(state.isLoggedIn, "didLogin 必须立刻置为已登录（界面要马上更新）")
        await waitUntil("喜欢的音乐加载") { await provider.likedIDCalls >= 1 }
        await waitUntil("用户歌单加载") { await provider.playlistCalls >= 1 }
        await waitUntil("收藏详情列表加载") { await provider.likedSongCalls >= 1 }
    }

    /// 冷启动恢复登录态时，用户歌单也要拉 —— 否则「添加到歌单」子菜单
    /// 在点开资料库 tab 之前恒为空。
    func testRestoreLoginStateLoadsLibraryData() async {
        // `restoreLoginState` 走的是 `NeteaseProvider.loadLoginCookie()` ——
        // 没有 cookie 它会直接 clearSession 并 return，压根不会去拉数据。
        // 这里种一张假 cookie：持久化已被 run-tests.sh 重定向到临时目录，
        // 修好 `PlaintextCredentialStore` 之前这一步读的是**开发者真实的凭据**。
        try? KeychainStore.shared.save("MUSIC_U=unit-test", for: .neteaseCookie)
        defer { try? KeychainStore.shared.delete(for: .neteaseCookie) }

        let provider = RecordingProvider(accountToReturn: AccountInfo(userID: "86080189", nickname: "测试"))
        let state = AppState(provider: provider)

        await state.restoreLoginState()

        XCTAssertTrue(state.isLoggedIn)
        await waitUntil("用户歌单加载") { await provider.playlistCalls >= 1 }
        await waitUntil("喜欢的音乐加载") { await provider.likedIDCalls >= 1 }
    }

    /// 没有登录态时，恢复流程不该去拉任何用户数据。
    func testRestoreWithoutAccountLoadsNothing() async {
        let provider = RecordingProvider(accountToReturn: nil)
        let state = AppState(provider: provider)

        await state.restoreLoginState()

        XCTAssertFalse(state.isLoggedIn)
        let playlists = await provider.playlistCalls
        let likedIDs = await provider.likedIDCalls
        XCTAssertEqual(playlists, 0, "未登录不该请求用户歌单")
        XCTAssertEqual(likedIDs, 0, "未登录不该请求收藏 id")
    }
    // MARK: - 会话失效 → 重新登录

    /// 会话失效禁用写操作，**重新登录必须解除禁用**。
    ///
    /// `needsReLogin` 原先只置位、没有任何地方复位：重新登录后 `isLoggedIn` 已是 true，
    /// 而 `canPerformWrite` 仍是 `true && !true == false`。于是 iOS 上点心形永远走
    /// 「未登录」分支 —— 每次都把登录弹窗再弹一遍，肉眼看就是「点了没反应」；
    /// 「添加到歌单」子菜单也整块消失。重启 App 才恢复，所以真机上极难定位。
    func testReLoginClearsNeedsReLogin() async {
        let account = AccountInfo(userID: "86080189", nickname: "测试")
        let state = AppState(provider: RecordingProvider())

        state.didLogin(account: account)
        XCTAssertTrue(state.canPerformWrite, "正常登录后必须能写")

        NotificationCenter.default.post(name: .clearToneSessionExpired, object: nil)
        await waitUntil("会话失效生效") { state.needsReLogin }
        XCTAssertFalse(state.isLoggedIn)
        XCTAssertFalse(state.canPerformWrite, "会话失效期间必须禁用写操作")

        state.didLogin(account: account)
        await waitUntil("重新登录解除写禁用") { !state.needsReLogin }
        XCTAssertTrue(
            state.canPerformWrite,
            "重新登录后不得继续禁用写操作，否则点心形只会反复弹登录窗"
        )
    }

    /// 会话失效 / 退出登录必须丢掉**内存里**的歌单。
    ///
    /// 原先只清磁盘缓存，内存那份留着：A 退出 → B 登录 → B 拉歌单失败时，
    /// 资料库会把 A 的歌单挂在 B 的账号下显示，点进去加载的也是 A 的歌单。
    func testSessionExpiryDropsPreviousAccountPlaylists() async {
        let state = AppState(provider: RecordingProvider())
        state.didLogin(account: AccountInfo(userID: "86080189", nickname: "测试"))
        await waitUntil("用户歌单加载") { !state.userPlaylists.isEmpty }
        XCTAssertEqual(state.userPlaylists.map(\.id), ["p1"])

        NotificationCenter.default.post(name: .clearToneSessionExpired, object: nil)
        await waitUntil("会话失效生效") { state.needsReLogin }
        XCTAssertTrue(
            state.userPlaylists.isEmpty,
            "旧账号的歌单不能留在内存里被下一个账号看到"
        )
    }

    // MARK: - 并发收藏回滚

    /// 并发收藏两首歌，其中一首失败：另一首的成功**不能**被一起回滚。
    ///
    /// 早期 `toggleLike` 把整份 `likedIDs`/`likedSongs` 快照下来，失败时整体还原。
    /// 用户很快点了两个心形（A 在途、B 已完成）时，A 失败会把 B 已经成功的收藏
    /// 一起抹掉并写回磁盘 —— 服务端认为 B 已收藏，本地却显示未收藏。
    func testConcurrentLikeRollbackKeepsOtherSongsSuccess() async {
        let provider = RecordingProvider(holdLikeIDs: ["a"], failLikeIDs: ["a"])
        let state = AppState(provider: provider)
        state.didLogin(account: AccountInfo(userID: "86080189", nickname: "测试"))
        await waitUntil("登录加载完成") { state.isLiked("s1") }

        let songA = Song(id: "a", title: "A", artists: [], source: .netease)
        let songB = Song(id: "b", title: "B", artists: [], source: .netease)

        // A 的写请求挂起
        let taskA = Task { await state.toggleLike(songA) }
        await waitUntil("A 的写请求挂起") { await provider.isLikeHeld("a") }
        XCTAssertTrue(state.isLiked("a"), "乐观更新应先把 A 标为已收藏")

        // B 在 A 还挂着的时候成功
        let taskB = Task { await state.toggleLike(songB) }
        let bSucceeded = await taskB.value
        XCTAssertTrue(bSucceeded, "B 的收藏应成功")
        XCTAssertTrue(state.isLiked("b"))

        // 放行 A，让它以限流错误失败
        await provider.releaseLike("a")
        let aSucceeded = await taskA.value
        XCTAssertFalse(aSucceeded, "A 的写入被限流，应返回切换前状态")
        XCTAssertFalse(state.isLiked("a"), "A 应回滚为未收藏")
        XCTAssertTrue(state.isLiked("b"), "A 的回滚不得抹掉 B 已经成功的收藏")
    }

    // MARK: - 喜欢详情列表的瞬时失败

    /// `fetchLikedSongs` 一次失败后，详情列表必须还能重试。
    ///
    /// 早期 `hasLoadedLikes` 在 id 拉回来后就置 true，详情失败也只是记日志：
    /// 之后所有 `loadLikedSongs()`（默认 force=false）都被 guard 挡下，
    /// 详情列表整场会话不再刷新，用户只看到「还没有喜欢的歌曲」。
    func testLikedSongsDetailRetriesAfterTransientFailure() async {
        let provider = RecordingProvider(failFirstLikedSongsFetch: true)
        let state = AppState(provider: provider)
        state.didLogin(account: AccountInfo(userID: "86080189", nickname: "测试"))

        await waitUntil("首次详情请求失败") { await provider.likedSongCalls >= 1 }
        XCTAssertTrue(state.isLiked("s1"), "id 已就位，心形应可用")

        // 再次加载：详情应重试并成功
        await state.loadLikedSongs()
        await waitUntil("详情重试成功") { await provider.likedSongCalls >= 2 }
        XCTAssertFalse(state.likedSongs.isEmpty, "详情失败后再次加载必须能恢复")
    }
    func testLateDetailsCannotOverwritePendingLike() async {
        let provider = RecordingProvider(holdLikeIDs: ["a"], holdLikedDetails: true)
        let state = AppState(provider: provider)
        state.didLogin(account: AccountInfo(userID: "one", nickname: "测试"))
        await waitUntil("收藏详情挂起") { await provider.isLikedDetailsHeld() }
        let task = Task { await state.toggleLike(Song(id: "a", title: "A", artists: [], source: .netease)) }
        await waitUntil("收藏写入挂起") { await provider.isLikeHeld("a") }
        await provider.releaseLikedDetails()
        await waitUntil("旧详情请求已结束") { await provider.playlistCalls > 0 }
        XCTAssertTrue(state.isLiked("a"))
        XCTAssertTrue(state.likedSongs.contains { $0.id == "a" })
        await provider.releaseLike("a")
        _ = await task.value
    }

    func testLateDetailsCannotOverwriteCompletedLike() async {
        let provider = RecordingProvider(holdLikedDetails: true)
        let state = AppState(provider: provider)
        state.didLogin(account: AccountInfo(userID: "one", nickname: "测试"))
        await waitUntil("收藏详情挂起") { await provider.isLikedDetailsHeld() }
        let liked = await state.toggleLike(Song(id: "a", title: "A", artists: [], source: .netease))
        XCTAssertTrue(liked)
        await provider.releaseLikedDetails()
        await waitUntil("旧详情请求已结束") { await provider.playlistCalls > 0 }
        XCTAssertTrue(state.isLiked("a"))
        XCTAssertTrue(state.likedSongs.contains { $0.id == "a" })
    }

    func testPreviousAccountLikeFailureCannotRollbackNewAccount() async {
        let provider = RecordingProvider(holdLikeIDs: ["a"], failLikeIDs: ["a"])
        let state = AppState(provider: provider)
        state.didLogin(account: AccountInfo(userID: "one", nickname: "旧账号"))
        await waitUntil("首次登录加载完成") { await provider.playlistCalls > 0 }
        let task = Task { await state.toggleLike(Song(id: "a", title: "A", artists: [], source: .netease)) }
        await waitUntil("旧账号收藏挂起") { await provider.isLikeHeld("a") }
        await state.performLogout()
        state.didLogin(account: AccountInfo(userID: "two", nickname: "新账号"))
        await waitUntil("新账号加载完成") { await provider.playlistCalls > 1 }
        await provider.releaseLike("a")
        _ = await task.value
        XCTAssertFalse(state.isLiked("a"))
        XCTAssertTrue(state.isLiked("s1"))
        XCTAssertFalse(state.isLikeWriteCoolingDown)
        XCTAssertNil(state.lastWriteError)
    }

    // MARK: - 迟到账号确认 / 同账号确认

    /// 冷启动的 `/user/account` 在途期间退出登录：迟到的响应不得把会话
    /// 恢复回来（旧实现在 await 之后无条件 `applyAccount`，用户刚退出就
    /// 会被重新「登录」；若旧 cookie 已死还会走 else 分支把新会话清掉）。
    func testLateAccountConfirmationCannotResurrectLoggedOutSession() async {
        try? KeychainStore.shared.save("MUSIC_U=unit-test", for: .neteaseCookie)
        defer { try? KeychainStore.shared.delete(for: .neteaseCookie) }
        PersistenceStore.shared.saveCachedAccount(AccountInfo(userID: "one", nickname: "旧账号"))
        defer { PersistenceStore.shared.clearCachedAccount() }

        let provider = RecordingProvider(
            accountToReturn: AccountInfo(userID: "one", nickname: "旧账号"),
            holdAccountInfo: true
        )
        let state = AppState(provider: provider)

        let restore = Task { await state.restoreLoginState() }
        await waitUntil("账号确认挂起") { await provider.isAccountInfoHeld() }
        XCTAssertTrue(state.isLoggedIn, "缓存账号应先把登录态立起来")

        await state.performLogout()

        await provider.releaseAccountInfo()
        await restore.value

        XCTAssertFalse(state.isLoggedIn, "迟到的账号确认不得把已退出的会话恢复回来")
        XCTAssertNil(state.account)
    }

    /// 同一账号的确认（缓存账号 → `/user/account` 确认是同一个人）不得
    /// 递增账号代次：`dataContextKey` 一变，iOS 上正在看的快照页会被
    /// 自己的 onChange 关掉，各页 `.task(id:)` 也白白重启一轮。
    func testSameAccountConfirmationKeepsDataContext() async {
        try? KeychainStore.shared.save("MUSIC_U=unit-test", for: .neteaseCookie)
        defer { try? KeychainStore.shared.delete(for: .neteaseCookie) }
        let account = AccountInfo(userID: "86080189", nickname: "测试")
        PersistenceStore.shared.saveCachedAccount(account)
        defer { PersistenceStore.shared.clearCachedAccount() }

        let provider = RecordingProvider(accountToReturn: account, holdAccountInfo: true)
        let state = AppState(provider: provider)

        let restore = Task { await state.restoreLoginState() }
        await waitUntil("账号确认挂起") { await provider.isAccountInfoHeld() }
        let keyBeforeConfirm = state.dataContextKey

        await provider.releaseAccountInfo()
        await restore.value

        XCTAssertEqual(
            state.dataContextKey, keyBeforeConfirm,
            "同一账号的确认改变了 dataContextKey —— 快照页会被误关"
        )
        XCTAssertTrue(state.isLoggedIn)
    }

    // MARK: - 用户数据磁盘缓存按账号隔离

    /// 直接锁住「键带 owner」这一层：不同账号的收藏 / 歌单缓存互不可见，
    /// 清除也只清自己那份。
    func testUserDataCachesAreScopedByOwner() {
        let a = "scope-owner-a"
        let b = "scope-owner-b"
        defer {
            PersistenceStore.shared.clearCachedLikedSongs(owner: a)
            PersistenceStore.shared.clearCachedLikedSongs(owner: b)
            PersistenceStore.shared.clearCachedUserPlaylists(owner: a)
            PersistenceStore.shared.clearCachedUserPlaylists(owner: b)
        }
        let song = Song(id: "s-scope", title: "T", artists: [], source: .netease)
        PersistenceStore.shared.saveCachedLikedSongs([song], owner: a)
        PersistenceStore.shared.saveCachedLikedSongIDs(["s-scope"], owner: a)
        PersistenceStore.shared.saveCachedUserPlaylists(
            [Playlist(id: "p-scope", name: "P", source: .netease)], owner: a
        )

        XCTAssertEqual(PersistenceStore.shared.loadCachedLikedSongs(owner: a).map(\.id), ["s-scope"])
        XCTAssertTrue(PersistenceStore.shared.loadCachedLikedSongs(owner: b).isEmpty)
        XCTAssertEqual(PersistenceStore.shared.loadCachedLikedSongIDs(owner: a), ["s-scope"])
        XCTAssertTrue(PersistenceStore.shared.loadCachedLikedSongIDs(owner: b).isEmpty)
        XCTAssertEqual(PersistenceStore.shared.loadCachedUserPlaylists(owner: a).map(\.id), ["p-scope"])
        XCTAssertTrue(PersistenceStore.shared.loadCachedUserPlaylists(owner: b).isEmpty)

        PersistenceStore.shared.clearCachedUserPlaylists(owner: a)
        XCTAssertTrue(PersistenceStore.shared.loadCachedUserPlaylists(owner: a).isEmpty, "清除只影响自己的账号")
        XCTAssertEqual(
            PersistenceStore.shared.loadCachedLikedSongs(owner: a).map(\.id), ["s-scope"],
            "清歌单缓存不该连带清收藏"
        )
    }

    /// 会话失效刻意保留磁盘缓存（同一账号重登不必把几百个请求重来一遍），
    /// 但下一个账号在拉取失败时**绝不能**把上一个账号的缓存当自己的数据显示。
    ///
    /// 旧实现用全局键存这些缓存，且 `loadUserPlaylists` 失败时保留「缓存内容」——
    /// 于是 B 登录（哪怕失败）看到的侧栏/资料库是 A 的歌单。
    func testOtherAccountCannotSeePreviousAccountsDiskCache() async {
        let providerA = RecordingProvider()
        let stateA = AppState(provider: providerA)
        stateA.didLogin(account: AccountInfo(userID: "disk-owner-one", nickname: "旧账号"))
        await waitUntil("旧账号歌单落盘") {
            !PersistenceStore.shared.loadCachedUserPlaylists(owner: "disk-owner-one").isEmpty
        }

        NotificationCenter.default.post(name: .clearToneSessionExpired, object: nil)
        await waitUntil("会话失效生效") { stateA.needsReLogin }
        XCTAssertFalse(
            PersistenceStore.shared.loadCachedUserPlaylists(owner: "disk-owner-one").isEmpty,
            "会话失效应保留磁盘缓存（这是刻意设计）"
        )

        // 新账号登录，但歌单拉取失败
        let providerB = RecordingProvider(failUserPlaylists: true)
        let stateB = AppState(provider: providerB)
        stateB.didLogin(account: AccountInfo(userID: "disk-owner-two", nickname: "新账号"))
        await waitUntil("新账号歌单请求已发出") { await providerB.playlistCalls >= 1 }

        XCTAssertTrue(
            stateB.userPlaylists.isEmpty,
            "新账号拉取失败时显示的必须是空列表，而不是上一个账号的磁盘缓存"
        )
    }

}