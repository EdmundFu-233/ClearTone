import XCTest
@testable import ClearTone

/// 歌手资料页的解析与分页测试。
///
/// 这一族接口的坑全在**字段名**上，而且是「返回 200 但字段读不到」那种 ——
/// 不对着上游 `api/module/artist_*.js` 与实测响应核，界面上只会看到
/// 「歌手没有 MV」「专辑一片空白」，不会有任何报错。
///
/// 这里的期望值都来自对仓库内 Node 运行时 + 真实响应的抓取
/// （`/api/artist/head/info/get`、`/api/v1/artist/songs`、
/// `/api/artist/introduction`、`/api/artist/mvs`、`/api/artist/albums/{id}`）。
final class ArtistProfileParsingTests: XCTestCase {

    // MARK: - /artist/detail（eapi）

    /// 实测 `data.artist` 的键：
    /// `id / cover / avatar / name / transNames / alias / identities /
    ///  identifyTag / briefDesc / rank / albumSize / musicSize / mvSize`
    ///
    /// **没有 `picUrl`** —— 头像字段叫 `cover` / `avatar`。
    /// 之前 `mapArtist` 只取 id + name，于是歌手页只能画一个写死的人形圆盘。
    func testArtistDetailUsesCoverAsAvatar() {
        let dict: [String: Any] = [
            "id": 6452,
            "name": "周杰伦",
            "cover": "https://p1.music.126.net/cover.jpg",
            "avatar": "https://p1.music.126.net/avatar.jpg",
            "alias": ["Jay Chou", "周董"],
            "briefDesc": "华语流行乐坛天王",
            "albumSize": 44,
            "musicSize": 568,
            "mvSize": 12,
        ]
        let artist = NeteaseProvider.mapArtist(dict)
        XCTAssertEqual(artist.id, "6452")
        XCTAssertEqual(artist.name, "周杰伦")
        XCTAssertEqual(artist.avatarURL?.absoluteString, "https://p1.music.126.net/cover.jpg")
        XCTAssertEqual(artist.alias, ["Jay Chou", "周董"])
        XCTAssertEqual(artist.displayNameWithAlias, "周杰伦 · Jay Chou")
    }

    /// `avatar` 也认 —— 两个字段名都要覆盖。
    func testArtistDetailFallsBackToAvatarField() {
        let dict: [String: Any] = ["id": 1, "name": "X", "avatar": "https://a/av.jpg"]
        XCTAssertEqual(NeteaseProvider.mapArtist(dict).avatarURL?.absoluteString, "https://a/av.jpg")
    }

    /// 四个来源字段全缺时必须是 nil（而不是 `URL(string: "")` 那种假地址）。
    func testArtistWithoutAnyImageFieldHasNilAvatar() {
        let artist = NeteaseProvider.mapArtist(["id": 1, "name": "X"])
        XCTAssertNil(artist.avatarURL)
    }

    /// `/simi/artist` 与 `/artist/album` 走的是 `picUrl` / `img1v1Url`。
    /// 实测相似歌手响应里 picUrl 一定有值，所以搜索结果里的歌手卡片也该有头像。
    func testSimilarArtistUsesPicUrl() {
        let dict: [String: Any] = [
            "id": 189409, "name": "林俊杰",
            "picUrl": "https://p1.music.126.net/pic.jpg",
            "img1v1Url": "https://p1.music.126.net/img1v1.jpg",
        ]
        XCTAssertEqual(NeteaseProvider.mapArtist(dict).avatarURL?.absoluteString,
                       "https://p1.music.126.net/pic.jpg")
    }

    /// 别名等于本名时不该显示成 `周杰伦 · 周杰伦`
    func testAliasEqualToNameIsNotShownTwice() {
        let artist = Artist(id: "1", name: "X", alias: ["X"])
        XCTAssertEqual(artist.displayNameWithAlias, "X")
    }

    func testEmptyAliasFallsBackToName() {
        XCTAssertEqual(Artist(id: "1", name: "X").displayNameWithAlias, "X")
    }

    // MARK: - 路由登记

    /// `/artist/detail` 的 module 用的是裸 `createOption(query)` →
    /// `util/option.js:3` 给出 `crypto: ''` → `util/request.js:218-221`
    /// 解析成 `encrypt ? 'eapi' : 'api'`，而 `util/config.json` 里
    /// `encrypt: true`。所以是 **eapi**，之前登记的 `.plain` 是错的。
    func testArtistDetailIsEapiNotPlain() {
        let endpoint = NeteaseEndpoint.endpoint(forRoute: "/artist/detail")
        XCTAssertEqual(endpoint?.crypto, .eapi)
        XCTAssertEqual(endpoint?.apiPath, "/api/artist/head/info/get")
    }

    /// `artist_album.js` 打的是 `/api/artist/albums/${query.id}`，
    /// 之前登记成 `/api/artist/album`（少了 s 与路径段）。
    func testArtistAlbumPathIsCorrected() {
        let endpoint = NeteaseEndpoint.endpoint(forRoute: "/artist/album")
        XCTAssertEqual(endpoint?.apiPath, "/api/artist/albums/{id}")
    }

    func testNewArtistRoutesAreMapped() {
        XCTAssertEqual(NeteaseEndpoint.endpoint(forRoute: "/artist/songs")?.apiPath,
                       "/api/v1/artist/songs")
        XCTAssertEqual(NeteaseEndpoint.endpoint(forRoute: "/artist/songs")?.crypto, .eapi)
        XCTAssertEqual(NeteaseEndpoint.endpoint(forRoute: "/artist/desc")?.apiPath,
                       "/api/artist/introduction")
        XCTAssertEqual(NeteaseEndpoint.endpoint(forRoute: "/artist/mv")?.apiPath,
                       "/api/artist/mvs")
    }

    // MARK: - eapi 键序

    /// `/artist/songs` 的 eapi 键序必须逐字等于 module 里 data 字面量的顺序。
    /// 顺序错了签名就错，症状是「接口报错」，极难定位。
    func testArtistSongsOrderedParams() throws {
        let payload = try XCTUnwrap(NeteaseEndpoint.orderedPayload(
            forRoute: "/artist/songs",
            query: ["id": "6452", "order": "hot", "offset": "0", "limit": "50"]
        ))
        XCTAssertEqual(
            OrderedJSON.encode(payload),
            #"{"id":"6452","private_cloud":"true","work_type":1,"order":"hot","offset":"0","limit":"50"}"#
        )
    }

    /// `private_cloud` / `work_type` 是 module **写死**的，不从 query 读。
    /// 传了会被 module 忽略，却会让直连层多拼两个上游不收的字段。
    func testModuleHardcodedParamsAreRejectedInQuery() {
        XCTAssertNil(NeteaseEndpoint.orderedPayload(
            forRoute: "/artist/songs",
            query: ["id": "1", "order": "hot", "offset": "0", "limit": "50",
                    "work_type": "1"]
        ))
    }

    /// 收藏改走 `/song/like`（eapi）：module 读 `query.id`/`query.uid`，
    /// 却放进 data 的 `trackId`/`userid`。重命名不登记的话直连层会拼错键名。
    func testSongLikeOrderedParamsUsesTrackIdAndUserid() throws {
        let payload = try XCTUnwrap(NeteaseEndpoint.orderedPayload(
            forRoute: "/song/like",
            query: ["id": "3438968283", "uid": "86080189", "like": "true"]
        ))
        XCTAssertEqual(
            OrderedJSON.encode(payload),
            #"{"trackId":"3438968283","userid":"86080189","like":"true"}"#
        )
    }

    /// 键名错成 `id`/`uid` 必须被挡住
    func testSongLikeRejectsUnrenamedKeys() {
        XCTAssertNil(NeteaseEndpoint.orderedPayload(
            forRoute: "/song/like",
            query: ["trackId": "1", "userid": "2", "like": "true"]
        ))
    }

    /// 收藏必须走 eapi 的 `/song/like`。
    ///
    /// 理由（实测）：weapi 的 `/api/radio/like` 在辅助进程匿名标识注册失败时
    /// 会被风控稳定拒成 `code 301`，同一实例上连开三次，而同 cookie 的
    /// `/user/account`、`/likelist` 全都 200。
    func testSongLikeUsesEapi() {
        let endpoint = NeteaseEndpoint.endpoint(forRoute: "/song/like")
        XCTAssertEqual(endpoint?.crypto, .eapi)
        XCTAssertEqual(endpoint?.apiPath, "/api/song/like")
    }

    // MARK: - /artist/mvs（weapi）

    /// MV 的元素结构与歌曲差很多：没有 `ar`/`al`，歌手名在扁平的 `artistName`，
    /// 封面优先 `imgurl16v9`（竖版，比 `imgurl` 宽版更适合列表左侧小方块）。
    func testArtistMVMapping() throws {
        let dict: [String: Any] = [
            "id": 22695250,
            "name": "任性 (5525 Live版)",
            "artistName": "周杰伦",
            "imgurl16v9": "https://p1.music.126.net/16v9.jpg",
            "imgurl": "https://p1.music.126.net/wide.jpg",
            "duration": 265000,
            "playCount": 104583,
            "publishTime": 1_465_000_000,
        ]
        let mv = try XCTUnwrap(NeteaseProvider.mapArtistMV(dict))
        XCTAssertEqual(mv.id, "22695250")
        XCTAssertEqual(mv.name, "任性 (5525 Live版)")
        XCTAssertEqual(mv.artistName, "周杰伦")
        XCTAssertEqual(mv.coverURL?.absoluteString, "https://p1.music.126.net/16v9.jpg")
        XCTAssertEqual(mv.duration, 265, accuracy: 0.001)
        XCTAssertEqual(mv.playCount, 104583)
        XCTAssertNotNil(mv.publishDate)
    }

    /// 没有 id 的条目必须丢掉（列表的 `Identifiable` 会因为重复 id 崩）
    func testArtistMVWithoutIDIsDropped() {
        XCTAssertNil(NeteaseProvider.mapArtistMV(["name": "无 id"]))
    }

    /// 缺时长/封面时用默认值，不要让 `as? Int` 失败变成 0 秒以外的东西
    func testArtistMVDefaultsWhenFieldsMissing() throws {
        let mv = try XCTUnwrap(NeteaseProvider.mapArtistMV(["id": 1, "name": "X"]))
        XCTAssertEqual(mv.duration, 0)
        XCTAssertEqual(mv.playCount, 0)
        XCTAssertNil(mv.coverURL)
        XCTAssertNil(mv.artistName)
    }

    // MARK: - followed

    /// `followed` 未登录时是缺失的 —— 必须是 nil（未知），不能是 false。
    /// 否则关注按钮在未登录时会显示成「未关注」而不是禁用。
    func testFollowedAcceptsMultipleEncodings() {
        XCTAssertEqual(NeteaseProvider.optionalBool(true), true)
        XCTAssertEqual(NeteaseProvider.optionalBool(false), false)
        XCTAssertEqual(NeteaseProvider.optionalBool(1), true)
        XCTAssertEqual(NeteaseProvider.optionalBool(0), false)
        XCTAssertEqual(NeteaseProvider.optionalBool("true"), true)
        XCTAssertEqual(NeteaseProvider.optionalBool("false"), false)
    }

    func testFollowedMissingIsNil() {
        XCTAssertNil(NeteaseProvider.optionalBool(nil))
        XCTAssertNil(NeteaseProvider.optionalBool("maybe"))
    }

    // MARK: - 空态

    func testEmptyPagesAreWellFormed() {
        XCTAssertTrue(ArtistSongPage.empty.songs.isEmpty)
        XCTAssertFalse(ArtistSongPage.empty.hasMore)
        XCTAssertTrue(ArtistAlbumPage.empty.albums.isEmpty)
        XCTAssertNil(ArtistAlbumPage.empty.isFollowed)
        XCTAssertTrue(ArtistMVPage.empty.mvs.isEmpty)
        XCTAssertTrue(ArtistIntro().isEmpty)
    }
}
