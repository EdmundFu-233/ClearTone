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

        init(accountToReturn: AccountInfo? = nil) {
            self.accountToReturn = accountToReturn
        }

        func fetchQRCodeKey() async throws -> String { "" }
        func fetchQRCodeImage(key: String) async throws -> URL {
            URL(string: "https://example.invalid/qr")!
        }
        func checkQRCodeStatus(key: String) async throws -> QRLoginStatus { .waitingScan }
        func logout() async throws {}
        func fetchAccountInfo() async throws -> AccountInfo? {
            accountCalls += 1
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
            return [Playlist(id: "p1", name: "我喜欢的音乐", source: .netease)]
        }
        func fetchLikedSongs() async throws -> [Song] {
            likedSongCalls += 1
            return [Song(id: "s1", title: "歌", artists: [], source: .netease)]
        }
        func fetchLikedSongIDs() async throws -> [String] {
            likedIDCalls += 1
            return ["s1"]
        }
        func likeSong(id: String, like: Bool) async throws {}
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

}
