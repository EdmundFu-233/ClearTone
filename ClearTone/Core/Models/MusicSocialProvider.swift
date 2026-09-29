import Foundation

/// 「社交 / 社区 / 资料库」能力。
///
/// ## 为什么不塞进 `MusicProvider`
///
/// `MusicProvider` 是**播放闭环**的最小接口：搜索、拿播放地址、歌词、队列。
/// 它被 `LocalProvider` 实现了 —— 本地 Provider
/// 天生没有歌单、评论、私信这些东西。
///
/// 而本协议里的能力**只有网易云在线账号才有**。硬塞进 `MusicProvider`
/// 会强迫两个本地 Provider 写几十个 `throw MusicError.notLoggedIn`，
/// 噪音大且毫无信息量。
///
/// 因此拆成两个协议，AppState 在需要时向下转型：
/// ```swift
/// guard let social = NeteaseProvider.shared as? MusicSocialProvider else { ... }
/// ```
///
/// ## 写操作约定
///
/// 所有写方法（收藏、加歌到歌单、删歌单、点赞评论…）都：
/// - **只抛错，不返回布尔**。成功即返回，失败带 `MusicError`；
/// - 由调用方做乐观更新与回滚（见 `AppState.toggleLike`）；
/// - 内部**必须 POST** —— 网易云对写接口的 GET 会返回 524/405。
public protocol MusicSocialProvider: CommentProvider {

    // MARK: - 歌单写操作

    /// 收藏 / 取消收藏歌单
    func subscribePlaylist(id: String, subscribe: Bool) async throws
    /// 新建歌单，返回创建后的歌单（含真实 id）
    func createPlaylist(name: String, isPrivate: Bool) async throws -> Playlist
    /// 删除歌单。`id` 支持逗号分隔批量删除
    func deletePlaylist(id: String) async throws
    /// 重命名歌单
    func updatePlaylistName(id: String, name: String) async throws
    /// 往歌单加歌
    ///
    /// 走 `/playlist/tracks?op=add`，**不是** `/playlist/track/add` ——
    /// 后者在 api-enhanced 里是「收藏视频到视频歌单」用的。
    func addSongsToPlaylist(playlistID: String, songIDs: [String]) async throws
    /// 从歌单删歌
    func removeSongsFromPlaylist(playlistID: String, songIDs: [String]) async throws

    // MARK: - 收藏专辑 / 歌手 / 电台

    func subscribeAlbum(id: String, subscribe: Bool) async throws
    func subscribeArtist(id: String, subscribe: Bool) async throws
    func subscribeRadio(id: String, subscribe: Bool) async throws

    // MARK: - 订阅列表

    func fetchSubscribedPlaylists(limit: Int) async throws -> [Playlist]
    func fetchSubscribedAlbums(limit: Int) async throws -> [Album]
    func fetchSubscribedArtists(limit: Int) async throws -> [Artist]
    func fetchSubscribedRadios(limit: Int) async throws -> [RadioStation]
    /// 电台详情（含电台名与订阅状态）
    func fetchRadioStationDetail(radioID: String) async throws -> RadioStation

    // MARK: - 榜单 / 分类

    /// 所有榜单（云音乐飙升榜、原创榜…）
    func fetchTopLists() async throws -> [TopList]
    /// 新歌速递
    func fetchTopSongs(area: TopSongArea) async throws -> [Song]
    /// 歌单广场（可按分类筛选）
    func fetchHotPlaylists(
        category: String?,
        order: TopPlaylistOrder,
        limit: Int,
        offset: Int
    ) async throws -> [Playlist]
    /// 歌单分类（语种 / 风格 / 场景 / 情感 / 主题）
    func fetchPlaylistCategories() async throws -> [PlaylistCategoryGroup]
    /// 热门歌单标签
    func fetchHotPlaylistTags() async throws -> [String]

    // MARK: - 推荐扩展

    /// 私人 FM（每次返回 3 首）
    func fetchPersonalFM() async throws -> [Song]
    /// 每日推荐歌单（与每日推荐歌曲互补）
    func fetchDailyRecommendPlaylists() async throws -> [Playlist]
    /// 新歌速递（`/personalized/newsong`，与 `fetchTopSongs` 不同源）
    func fetchNewSongs(limit: Int) async throws -> [Song]
    /// 最新专辑
    func fetchNewAlbums(limit: Int) async throws -> [Album]
    /// 相似歌曲
    func fetchSimilarSongs(songID: String, limit: Int) async throws -> [Song]
    /// 相似歌手
    func fetchSimilarArtists(artistID: String) async throws -> [Artist]
    /// 「不喜欢」—— 让每日推荐真正学会你的口味
    ///
    /// `songID` 取 `/recommend/songs` 返回的歌曲 `id`：`home.md` 的调用例子
    /// `/recommend/songs/dislike?id=168091` 用的就是一个真实歌曲 id，
    /// 日推响应里也不存在另一套 recommendId。
    ///
    /// 成功时接口会返回一首**替补歌曲**（`data`），调用方应当把它补进列表，
    /// 否则用户点完「不喜欢」会发现歌单变短了。
    @discardableResult
    func dislikeDailyRecommend(songID: String) async throws -> Song?

    // MARK: - 搜索辅助

    func fetchSearchSuggestions(keyword: String) async throws -> [SearchSuggestion]
    func fetchHotSearchTerms() async throws -> [HotSearchTerm]

    // MARK: - 评论

    // 读取、分页与点赞接口继承自 CommentProvider。

    // MARK: - 消息

    func fetchNotices(limit: Int) async throws -> [UserNotice]
    func fetchPrivateConversations(limit: Int, offset: Int) async throws -> [PrivateConversation]
    func fetchPrivateMessages(userID: String, limit: Int) async throws -> [PrivateMessage]
    /// 我发出的评论
    func fetchMyComments(limit: Int) async throws -> [MyComment]

    // MARK: - 账号数据

    func fetchUserLevel() async throws -> UserLevelInfo
    /// 听歌排行。`weekly` 为 true 取最近一周，否则全部时间
    func fetchListenRecords(weekly: Bool) async throws -> [ListenRecord]
    /// 听歌打卡
    func dailySignIn() async throws -> SignInResult
    /// 收藏数量汇总（歌单/专辑/歌手/电台/歌曲）
    func fetchUserCounts() async throws -> [String: Int]
}
