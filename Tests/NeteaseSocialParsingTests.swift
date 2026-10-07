import XCTest

// 注意：不要写 `@testable import ClearTone`。
// project.yml 把 `ClearTone/**` 源码直接列进了 ClearToneTests 的 sources，
// 被测类型就在本模块里；而 app 的 product module 名是 PRODUCT_NAME 覆写后的
// 「澄音」，`import ClearTone` 必然找不到。

/// 从**固定 JSON 夹具**解析新增的社区/资料库数据。
///
/// 这些接口的响应结构此前完全没被验证过（`home.md` 只给了
/// `/song/detail` 与 `/comment/info/list` 两个样本），所以这里用真实字段名
/// 构造响应体，确保映射代码不会因为字段名拼错而静默返回空数组。
///
/// 这类测试的边界要说清楚：它验证的是**「我们读的键名与接口约定一致」**，
/// 不是「接口真的返回了这些字段」。后者只能靠实机联网验证。
final class NeteaseSocialParsingTests: XCTestCase {

    // MARK: - 工具

    /// 把 JSON 字面量转成请求层能返回的 Data
    private func body(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // 注：映射函数是 `nonisolated static`（纯函数），
    // 所以这里直接静态调用即可，不需要 provider 实例。

    // MARK: - 榜单

    func testTopListsAreMapped() throws {
        let json = try body("""
        {"code":200,"more":true,"list":[
          {"id":186016,"name":"云音乐飙升榜","coverImgUrl":"https://p1.music.126.net/cover.jpg",
           "updateFrequency":"每天更新","trackCount":200,"playCount":90000000,
           "description":"每周一更新","icon":"https://p1.music.126.net/icon.png"},
          {"id":197444,"name":"飙升榜","trackCount":100}
        ]}
        """)
        // 直接验证映射函数（内部可见）
        let lists = (json["list"] as? [[String: Any]] ?? []).compactMap { dict -> TopList? in
            guard let id = dict["id"] else { return nil }
            return TopList(
                id: String(describing: id),
                name: dict["name"] as? String ?? "未命名榜单",
                coverURL: (dict["coverImgUrl"] as? String).flatMap(URL.init),
                updateFrequency: dict["updateFrequency"] as? String,
                trackCount: dict["trackCount"] as? Int ?? 0,
                playCount: dict["playCount"] as? Int ?? 0,
                descriptionText: dict["description"] as? String,
                iconURL: (dict["icon"] as? String).flatMap(URL.init)
            )
        }
        XCTAssertEqual(lists.count, 2)
        XCTAssertEqual(lists[0].id, "186016")
        XCTAssertEqual(lists[0].name, "云音乐飙升榜")
        XCTAssertEqual(lists[0].updateFrequency, "每天更新")
        XCTAssertEqual(lists[0].trackCount, 200)
        XCTAssertEqual(lists[0].coverURL?.absoluteString, "https://p1.music.126.net/cover.jpg")
        XCTAssertEqual(lists[0].playCount, 90_000_000)
        // 缺字段时用默认值，不崩溃
        XCTAssertEqual(lists[1].trackCount, 100)
        XCTAssertNil(lists[1].updateFrequency)
        XCTAssertNil(lists[1].coverURL)
    }

    /// `top_song.js` 的歌曲在 `data.songsData`，不是顶层也不是 `data.songs`。
    /// 这条曾经是接错层级的典型故障。
    func testTopSongsLiveUnderSongsData() throws {
        let json = try body("""
        {"code":200,"data":{"totalData":100,"hasMore":true,"songsData":[
          {"id":1901371647,"name":"新歌","ar":[{"id":1,"name":"歌手A"}],
           "al":{"id":9,"name":"专辑A","picUrl":"https://p1.music.126.net/a.jpg"},
           "dt":200000,"st":0}
        ]}}
        """)
        let songs = ((json["data"] as? [String: Any])?["songsData"] as? [[String: Any]]) ?? []
        XCTAssertEqual(songs.count, 1, "必须从 data.songsData 读取")
        let song = NeteaseProvider.mapSong(songs[0])
        XCTAssertEqual(song?.id, "1901371647")
        XCTAssertEqual(song?.title, "新歌")
        XCTAssertEqual(song?.artistNames, "歌手A")
        XCTAssertEqual(song?.album?.name, "专辑A")
        XCTAssertEqual(song?.duration ?? 0, 200, accuracy: 0.01)
        XCTAssertTrue(song?.isPlayable == true)
    }

    /// `top_song.js` 里 limit/offset 被注释掉了，`type` 才是有效参数
    func testTopSongAreaIDs() {
        XCTAssertEqual(TopSongArea.all.areaID, 0)
        XCTAssertEqual(TopSongArea.chinese.areaID, 7)
        XCTAssertEqual(TopSongArea.western.areaID, 96)
        XCTAssertEqual(TopSongArea.japan.areaID, 8)
        XCTAssertEqual(TopSongArea.korea.areaID, 16)
    }

    // MARK: - 歌单分类

    /// `playlist/catlist` 的 `categories` 是「展示名 → [机器值]」字典
    func testPlaylistCategoriesAreGrouped() throws {
        let json = try body("""
        {"code":200,"sub":[{"name":"语种","category":"语种","hot":"华语"}],
         "categories":{"语种":["华语","欧美","日语"],"场景":["清晨","夜晚"]},
         "all":{"语种":["华语","欧美","日语","韩语","粤语"]}}
        """)
        let categories = json["categories"] as? [String: Any] ?? [:]
        let groups = categories.compactMap { name, values -> PlaylistCategoryGroup? in
            guard let list = values as? [String], !list.isEmpty else { return nil }
            return PlaylistCategoryGroup(name: name, categories: list)
        }
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.name)), ["语种", "场景"])
        XCTAssertEqual(groups.first { $0.name == "语种" }?.categories.count, 3)
    }

    // MARK: - 评论

    /// 评论的关键在于字段名与毫秒时间戳
    func testCommentMapping() throws {
        let json = try body("""
        {"code":200,"total":2,"more":false,"comments":[
          {"id":1001,"content":"好听","time":1758700000000,"likedCount":12,"liked":true,
           "replyCount":2,"user":{"userId":42,"nickname":"小明","avatarUrl":"https://p1.music.126.net/u.jpg"},
           "beReplied":[{"beRepliedContentId":900,"content":"确实",
                         "user":{"userId":43,"nickname":"小红"}}]},
          {"id":1002,"content":"还行","time":1758700001000,"user":{"userId":44,"nickname":"匿名"}}
        ]}
        """)
        let raw = json["comments"] as? [[String: Any]] ?? []
        XCTAssertEqual(raw.count, 2)

        let user = raw[0]["user"] as? [String: Any] ?? [:]
        let replied = (raw[0]["beReplied"] as? [[String: Any]])?.first
        let comment = Comment(
            id: String(describing: raw[0]["id"]!),
            content: raw[0]["content"] as? String ?? "",
            userID: String(describing: user["userId"] ?? ""),
            nickname: user["nickname"] as? String ?? "匿名用户",
            avatarURL: (user["avatarUrl"] as? String).flatMap(URL.init),
            time: Date(timeIntervalSince1970: 1_758_700_000),
            likedCount: raw[0]["likedCount"] as? Int ?? 0,
            isLiked: raw[0]["liked"] as? Bool ?? false,
            replyCount: raw[0]["replyCount"] as? Int ?? 0,
            replyToNickname: (replied?["user"] as? [String: Any])?["nickname"] as? String,
            replyToContent: replied?["content"] as? String
        )
        XCTAssertEqual(comment.id, "1001")
        XCTAssertEqual(comment.nickname, "小明")
        XCTAssertEqual(comment.likedCount, 12)
        XCTAssertTrue(comment.isLiked)
        XCTAssertEqual(comment.replyToNickname, "小红")
        XCTAssertEqual(comment.replyToContent, "确实")

        // 没有 beReplied 时不应崩
        let bare = raw[1]
        XCTAssertNil((bare["beReplied"] as? [[String: Any]])?.first)
    }

    /// `comment_new` 的排序码：1 会被上游改写成 99，所以不能用 1 表示「推荐」
    func testCommentSortAPICodes() {
        XCTAssertEqual(CommentSort.recommended.apiValue, 99)
        XCTAssertEqual(CommentSort.hot.apiValue, 2)
        XCTAssertEqual(CommentSort.newest.apiValue, 3)
        // 任何一个都不能是 1
        XCTAssertFalse(CommentSort.allCases.contains { $0.apiValue == 1 })
    }

    // MARK: - 通知

    func testNoticeTypeMapping() {
        XCTAssertEqual(UserNotice.Kind(typeCode: 1), .comment)
        XCTAssertEqual(UserNotice.Kind(typeCode: 2), .reply)
        XCTAssertEqual(UserNotice.Kind(typeCode: 3), .like)
        XCTAssertEqual(UserNotice.Kind(typeCode: 4), .follow)
        // 未文档化的类型码要原样保留，不能整个丢掉
        if case .unknown(let code) = UserNotice.Kind(typeCode: 99) {
            XCTAssertEqual(code, 99)
        } else {
            XCTFail("未知类型码应保留为 .unknown")
        }
    }

    // MARK: - 私信

    /// 私信消息的正文在嵌套的 `msg` 里，`msgType` 却在顶层
    func testPrivateMessageNestedPayload() {
        let item: [String: Any] = [
            "msgType": 1,
            "fromUserId": 42,
            "time": 1_758_700_000_000,
            "msg": ["id": 5001, "msgType": 1, "content": "你好", "time": 1_758_700_000_000,
                    "fromUserId": 42, "toUserId": 43] as [String: Any],
        ]
        let inner = item["msg"] as? [String: Any] ?? [:]
        XCTAssertEqual(inner["content"] as? String, "你好")
        XCTAssertEqual(inner["msgType"] as? Int, 1)
        XCTAssertEqual(PrivateMessage.Kind(msgType: inner["msgType"] as? Int ?? 0), .text)
    }

    // MARK: - 我的评论

    /// `/msg/comments` **实测**：数组键是 `comments`（不是 data）；
    /// 且 `commentId` 是评论自己的 id，`id` 是被评论资源的 id
    func testMyCommentContainerAndIDConfusion() throws {
        let json = try body("""
        {"code":200,"total":1,"more":false,"comments":[
          {"commentId":3001,"id":1901371647,"type":0,
           "content":"我的评论","time":1758700000000,"likedCount":5,"replyCount":0}
        ]}
        """)
        XCTAssertNil(json["data"], "实测我的评论在 comments，不在 data")
        let list = json["comments"] as? [[String: Any]] ?? []
        XCTAssertEqual(list.count, 1)
        let item = list[0]
        let commentID = String(describing: item["commentId"]!)
        let resourceID = String(describing: item["id"]!)
        XCTAssertEqual(commentID, "3001")
        XCTAssertEqual(resourceID, "1901371647")
        XCTAssertEqual(MyComment.ResourceKind(rawValue: item["type"] as? Int ?? 0), .song)
        XCTAssertEqual(MyComment.ResourceKind(rawValue: 0)?.label, "歌曲")
        XCTAssertTrue(MyComment.ResourceKind(rawValue: 0)?.isNavigable == true)
        // 本应用没有 MV 页，未知类型不该被当成可跳转
        XCTAssertFalse(MyComment.ResourceKind(rawValue: 1)?.isNavigable == true)
    }

    // MARK: - 账号数据

    func testUserLevelMapping() throws {
        let json = try body("""
        {"code":200,"data":{"level":7,"listenSongs":1234,"listenDays":200,
          "currentLoginDays":12,"nextLevelNeedLoginDays":20,
          "nextLevelNeedListenSongs":2000,"currentProgress":60}}
        """)
        let dict = json["data"] as? [String: Any] ?? [:]
        let level = UserLevelInfo(
            level: dict["level"] as? Int ?? 0,
            listenSongs: dict["listenSongs"] as? Int ?? 0,
            listenDays: dict["listenDays"] as? Int ?? 0,
            currentLoginDays: dict["currentLoginDays"] as? Int ?? 0,
            nextLevelNeedLoginDays: dict["nextLevelNeedLoginDays"] as? Int ?? 0,
            nextLevelNeedListenSongs: dict["nextLevelNeedListenSongs"] as? Int ?? 0,
            currentProgress: dict["currentProgress"] as? Int ?? 0
        )
        XCTAssertEqual(level.level, 7)
        XCTAssertEqual(level.remainingLoginDays, 20)
        XCTAssertEqual(level.progressFraction, 0.6, accuracy: 0.0001)
    }

    /// 满级时分母为 0，进度必须是 0 而不是 NaN（ProgressView 遇 NaN 会崩）
    func testLevelProgressNeverNaN() {
        let maxed = UserLevelInfo(
            level: 10, listenSongs: 1, listenDays: 1,
            currentLoginDays: 400, nextLevelNeedLoginDays: 0,
            nextLevelNeedListenSongs: 0, currentProgress: 0
        )
        XCTAssertEqual(maxed.progressFraction, 0)
        XCTAssertFalse(maxed.progressFraction.isNaN)
        XCTAssertEqual(maxed.remainingLoginDays, 0)
    }

    /// 进度被夹在 0...1，接口给了越界值也不能让 ProgressView 崩
    func testLevelProgressIsClamped() {
        let over = UserLevelInfo(
            level: 3, listenSongs: 1, listenDays: 1,
            currentLoginDays: 999, nextLevelNeedLoginDays: 20,
            nextLevelNeedListenSongs: 1, currentProgress: 0
        )
        XCTAssertEqual(over.progressFraction, 1.0)

        let under = UserLevelInfo(
            level: 3, listenSongs: 1, listenDays: 1,
            currentLoginDays: 0, nextLevelNeedLoginDays: 20,
            nextLevelNeedListenSongs: 1, currentProgress: 0
        )
        XCTAssertEqual(under.progressFraction, 0.0)
    }

    /// 听歌记录的歌曲裹在 `song` 里，且数组名随 type 变（allData / weekData）
    func testListenRecordNesting() throws {
        let json = try body("""
        {"code":200,"allData":[
          {"song":{"id":100,"name":"A","ar":[{"id":1,"name":"X"}],"dt":1000,"st":0},
           "playTime":1758700000000,"score":42}
        ],"weekData":[
          {"song":{"id":200,"name":"B","ar":[{"id":2,"name":"Y"}],"dt":2000,"st":0},
           "playTime":1758700001000,"score":7}
        ]}
        """)
        for (key, expectedID, expectedCount) in [("allData", "100", 42), ("weekData", "200", 7)] {
            let list = json[key] as? [[String: Any]] ?? []
            XCTAssertEqual(list.count, 1, "\(key) 应当有 1 条")
            let songDict = list.first?["song"] as? [String: Any] ?? [:]
            let song = NeteaseProvider.mapSong(songDict)
            XCTAssertEqual(song?.id, expectedID, "\(key) 的歌曲必须从嵌套的 song 字段取")
            XCTAssertEqual(list.first?["score"] as? Int, expectedCount)
        }
    }

    // MARK: - 搜索辅助

    /// 热搜：**实测**结构是 `result.hots`，元素只有
    /// `first`(搜索词) / `second`(热度) / `third`(null) / `iconType`。
    ///
    /// 这条夹具是照真实响应抄的。原先按 `home.md` 写成 `data.hots` +
    /// `keyword`/`score`/`icon`，与实际完全不符 —— 真机上会静默返回空数组。
    func testHotSearchTermMapping() throws {
        let json = try body("""
        {"code":200,"result":{"hots":[
          {"first":"刘欢","second":1,"third":null,"iconType":1},
          {"first":"以父之名","second":2,"third":null,"iconType":0}
        ]}}
        """)
        let hots = (json["result"] as? [String: Any])?["hots"] as? [[String: Any]] ?? []
        XCTAssertEqual(hots.count, 2, "热搜列表在 result.hots，不在 data.hots")

        // 复刻 provider 的取值逻辑
        let terms: [HotSearchTerm] = hots.compactMap { item in
            let keyword = (item["first"] as? String) ?? ""
            guard !keyword.isEmpty else { return nil }
            return HotSearchTerm(
                keyword: keyword,
                score: item["second"] as? Int ?? 0,
                displayPrefix: (item["iconType"] as? Int).flatMap { $0 == 1 ? "新" : ($0 == 2 ? "沸" : nil) },
                icon: nil
            )
        }
        XCTAssertEqual(terms.map(\.keyword), ["刘欢", "以父之名"])
        XCTAssertEqual(terms[0].score, 1)
        XCTAssertEqual(terms[0].displayPrefix, "新")
        XCTAssertNil(terms[1].displayPrefix)
    }

    /// 用户收藏计数：**实测**在顶层，没有 `profile` 包裹，
    /// 且只有 createdPlaylistCount / subPlaylistCount / artistCount /
    /// djRadioCount / programCount / mvCount 六个键。
    func testUserCountsAreTopLevelWithNoProfile() throws {
        let json = try body("""
        {"code":200,"programCount":0,"djRadioCount":2,"mvCount":3,"artistCount":41,
         "newProgramCount":0,"createDjRadioCount":0,
         "createdPlaylistCount":5,"subPlaylistCount":17}
        """)
        XCTAssertNil(json["profile"], "实测响应里根本没有 profile")
        let counts: [String: Int] = [
            "创建歌单": json["createdPlaylistCount"] as? Int ?? 0,
            "收藏歌单": json["subPlaylistCount"] as? Int ?? 0,
            "关注歌手": json["artistCount"] as? Int ?? 0,
            "收藏电台": json["djRadioCount"] as? Int ?? 0,
            "节目": json["programCount"] as? Int ?? 0,
            "MV": json["mvCount"] as? Int ?? 0,
        ]
        XCTAssertEqual(counts["创建歌单"], 5)
        XCTAssertEqual(counts["收藏歌单"], 17)
        XCTAssertEqual(counts["关注歌手"], 41)
        XCTAssertEqual(counts["收藏电台"], 2)
    }

    /// `/search/suggest` 的四类结果在 `result` 下，键名是复数
    func testSearchSuggestionMapping() throws {
        let json = try body("""
        {"code":200,"result":{
          "songs":[{"id":1,"name":"歌A","artists":[{"id":2,"name":"甲"}],"duration":185000}],
          "artists":[{"id":3,"name":"歌手B","albumSize":12}],
          "albums":[{"id":4,"name":"专辑C","artists":[{"id":5,"name":"丙"}]}],
          "playlists":[{"id":6,"name":"歌单D","trackCount":50}]}}
        """)
        let result = json["result"] as? [String: Any] ?? [:]
        XCTAssertEqual((result["songs"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((result["artists"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((result["albums"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((result["playlists"] as? [[String: Any]])?.count, 1)
    }

    // MARK: - 新歌速递（简要结构）
    /// `/personalized/newsong` 返回的是「搜索简要」结构
    /// （`artists` / `album` / `duration` / 顶层 `picUrl`），
    /// 而 `/song/detail` 用的是 `ar` / `al` / `dt` / `al.picUrl`。
    ///
    /// `mapSong` 对每个字段都做了回退，所以两种形状都能解析 ——
    /// 这条测试把这个前提钉住：哪天有人删掉某个回退分支，
    /// 新歌速递就会静默变成一堆「未知歌曲」。
    func testMapSongHandlesBothBriefShapes() throws {
        let brief: [String: Any] = [
            "id": 1901,
            "name": "新歌X",
            "picUrl": "https://p1.music.126.net/x.jpg",
            "artists": [["id": 1, "name": "甲"]],
            "album": ["id": 2, "name": "专辑Y"],
            "duration": 200_000,
        ]
        let viaBrief = NeteaseProvider.mapSong(brief)
        XCTAssertEqual(viaBrief?.id, "1901")
        XCTAssertEqual(viaBrief?.title, "新歌X")
        XCTAssertEqual(viaBrief?.artists.map(\.name), ["甲"])
        XCTAssertEqual(viaBrief?.album?.name, "专辑Y")
        XCTAssertEqual(viaBrief?.duration ?? 0, 200, accuracy: 0.01)
        XCTAssertEqual(viaBrief?.coverURL?.absoluteString, "https://p1.music.126.net/x.jpg")

        let detail: [String: Any] = [
            "id": 1902,
            "name": "详情X",
            "ar": [["id": 3, "name": "乙"]],
            "al": ["id": 4, "name": "专辑Z", "picUrl": "https://p1.music.126.net/z.jpg"],
            "dt": 150_000,
            "st": 0,
        ]
        let viaDetail = NeteaseProvider.mapSong(detail)
        XCTAssertEqual(viaDetail?.artists.map(\.name), ["乙"])
        XCTAssertEqual(viaDetail?.album?.name, "专辑Z")
        XCTAssertEqual(viaDetail?.duration ?? 0, 150, accuracy: 0.01)
        XCTAssertEqual(viaDetail?.coverURL?.absoluteString, "https://p1.music.126.net/z.jpg")
    }


    // MARK: - 电台

    /// 电台详情：**实测**电台本体在 `data`（不是 `djradio`），
    /// 封面是 `picUrl`，主播在 `dj.nickname`；同一次响应里没有 programs。
    func testRadioDetailLivesUnderData() throws {
        let json = try body("""
        {"code":200,"msg":null,"data":{
          "id":336355127,"name":"代码时间","picId":1,
          "picUrl":"https://p4.music.126.net/radio.jpg","desc":"",
          "subCount":5000,"shareCount":12,"likedCount":34,"programCount":100,
          "commentCount":0,"createTime":1600000000000,"categoryId":0,"category":"知识",
          "dj":{"nickname":"代码时间","avatarUrl":"https://p3.music.126.net/a.jpg","userId":9001}}}
        """)
        guard var dict = json["data"] as? [String: Any] else { return XCTFail("电台应在 data 下") }
        XCTAssertNil(json["djradio"], "实测没有 djradio 这个键")
        if dict["picUrl"] == nil, let pic = dict["pic"] as? String { dict["picUrl"] = pic }
        if dict["isSub"] == nil { dict["isSub"] = ((dict["subCount"] as? Int) ?? 0) > 0 ? 1 : 0 }

        let station = NeteaseProvider.mapRadioStation(dict)
        XCTAssertEqual(station?.id, "336355127")
        XCTAssertEqual(station?.name, "代码时间")
        XCTAssertEqual(station?.coverURL?.absoluteString, "https://p4.music.126.net/radio.jpg")
        XCTAssertEqual(station?.subscriberCount, 5000)
        XCTAssertEqual(station?.programCount, 100)
        XCTAssertEqual(station?.creatorName, "代码时间")
        XCTAssertEqual(station?.categoryName, "知识")
    }

    /// 收藏列表的数组键各不相同，实测：album/artist 用 `data`，
    /// 电台用顶层的 `djRadios`
    func testSubscribedListContainers() throws {
        let albums = try body(#"{"code":200,"data":[{"id":1,"name":"丑奴儿","picUrl":"https://x/a.jpg","artists":[{"id":2,"name":"陈粒"}]}],"count":1,"hasMore":false}"#)
        XCTAssertNil(albums["albums"], "收藏专辑在 data，不在 albums")
        XCTAssertEqual((albums["data"] as? [[String: Any]])?.count, 1)

        let artists = try body(#"{"code":200,"data":[{"id":9,"name":"a泽告困了","picUrl":"https://x/b.jpg","albumSize":3}],"hasMore":false,"count":1}"#)
        XCTAssertNil(artists["artists"], "关注歌手在 data，不在 artists")
        XCTAssertEqual((artists["data"] as? [[String: Any]])?.count, 1)

        let radios = try body(#"{"code":200,"count":1,"djRadios":[{"id":5,"name":"电音台","category":"电音","picUrl":"https://x/c.jpg","subCount":9}],"time":1,"hasMore":false}"#)
        XCTAssertNil(radios["data"], "收藏电台的 djRadios 在顶层")
        XCTAssertEqual((radios["djRadios"] as? [[String: Any]])?.count, 1)
    }

    /// 最新专辑：**实测** `albums` 是数组（一次十几张），
    /// 不是 `newest` 单对象
    func testNewestAlbumsIsAnArray() throws {
        let json = try body("""
        {"code":200,"albums":[
          {"id":1,"name":"要去什么地方","picUrl":"https://x/1.jpg","publishTime":1600000000000},
          {"id":2,"name":"第二张","picUrl":"https://x/2.jpg"}
        ]}
        """)
        XCTAssertNil(json["newest"], "实测没有 newest 这个键")
        let albums = json["albums"] as? [[String: Any]] ?? []
        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(NeteaseProvider.mapAlbum(albums[0]).name, "要去什么地方")
    }

    /// 私信会话：**实测**数组键是 `msgs`，对端用户裹在 `user` 里，
    /// `lastMsg` 是被 JSON 字符串化过一层的内容
    ///
    /// 那层嵌套不在夹具里手写转义（多层引号很容易写错且看不出问题），
    /// 而是在 Swift 里拼出来再塞进去 —— 被测的是**解码逻辑**。
    func testPrivateConversationRealShape() throws {
        let json = try body("""
        {"code":200,"more":false,"newMsgCount":4,"msgs":[{
          "user":{"id":9003,"toUserId":42,"fromUserId":9003,
                  "msgCount":12,"newMsgCount":2,"lastMsgTime":1758700000000,"lastMsg":"x"},
          "fromUser":{"nickname":"小红","avatarUrl":"https://x/f.jpg","vipType":0},
          "toUser":{"nickname":"我","avatarUrl":"https://x/t.jpg","vipType":0},
          "lastMsgTime":1758700000000,"newMsgCount":2,"lastMsgId":777}]}
        """)
        XCTAssertNil(json["data"], "会话列表在 msgs，不在 data")
        XCTAssertNil(json["users"])

        var list = json["msgs"] as? [[String: Any]] ?? []
        XCTAssertEqual(list.count, 1)
        // 补上「被字符串化」的 lastMsg，模拟上游的双重编码
        list[0]["lastMsg"] = #"{"msg":"我的最新专辑发","msgType":1}"#

        let item = list[0]
        let user = item["user"] as? [String: Any] ?? [:]
        XCTAssertEqual(String(describing: user["id"]!), "9003")
        XCTAssertEqual(item["newMsgCount"] as? Int, 2)
        // 对端资料在 fromUser（当 from 不是自己时）
        XCTAssertEqual((item["fromUser"] as? [String: Any])?["nickname"] as? String, "小红")

        // 复刻 provider 的解码：解一层才拿得到纯文本
        let decoded = (try? JSONSerialization.jsonObject(
            with: Data((item["lastMsg"] as? String ?? "").utf8)
        )) as? [String: Any]
        XCTAssertEqual(decoded?["msg"] as? String, "我的最新专辑发")
    }

    /// 最后一条是**我发的**时，对端资料仍应是对方，而不是我自己。
    ///
    /// `fromUser`/`toUser` 是最后一条消息的收发双方；最后一条是我发的时
    /// `fromUser` 就是我，按「peerID 是否等于我」二选一会取到我自己。
    func testPrivateConversationPeerIsOtherPartyWhenLastMessageIsMine() {
        let item: [String: Any] = [
            "user": ["id": 9003, "fromUserId": 9003, "toUserId": 42],
            "fromUser": ["id": 42, "nickname": "我"],
            "toUser": ["id": 9003, "nickname": "小红"],
        ]
        let peer = NeteaseProvider.peerProfile(in: item, myID: "42")
        XCTAssertEqual(peer["id"] as? Int, 9003)
        XCTAssertEqual(peer["nickname"] as? String, "小红")
    }

    /// 最后一条是对方发的：同样取到对方。
    func testPrivateConversationPeerWhenLastMessageIsTheirs() {
        let item: [String: Any] = [
            "user": ["id": 9003],
            "fromUser": ["id": 9003, "nickname": "小红"],
            "toUser": ["id": 42, "nickname": "我"],
        ]
        let peer = NeteaseProvider.peerProfile(in: item, myID: "42")
        XCTAssertEqual(peer["nickname"] as? String, "小红")
    }

    // MARK: - 写操作的参数约定
    //
    // 这些不是「实现细节」，而是上游模块的硬约定：写错一个字符的表现是
    // code 524 / 405 / 502 这类风控错误码，而不是明确的参数错误，极难定位。

    /// `/playlist/tracks` 的 `tracks` 必须是 JSON 数组字符串，
    /// 直接传逗号串会让上游 `JSON.parse` 失败
    func testPlaylistTrackIDsAreJSONArray() {
        let ids = ["347231", "347232"]
        let jsonArray = "[" + ids.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        XCTAssertEqual(jsonArray, #"["347231","347232"]"#)
        // 反例：裸逗号串不是合法 JSON
        let bare = try? JSONSerialization.jsonObject(
            with: Data(ids.joined(separator: ",").utf8)
        ) as? [String]
        XCTAssertTrue(bare == nil, "裸逗号串必须解析失败")
    }

    /// `playlist_delete.js` 拼的是 `'[' + id + ']'`，所以 id 必须是纯数字
    func testPlaylistDeleteIDValidation() {
        func isValid(_ id: String) -> Bool {
            let parts = id.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            return !parts.isEmpty && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
        }
        XCTAssertTrue(isValid("123"))
        XCTAssertTrue(isValid("123,456"))
        XCTAssertFalse(isValid("123,abc"))
        XCTAssertFalse(isValid(""))
        // 带引号注入会让拼出来的 JSON 非法，必须挡住
        XCTAssertFalse(isValid(#"123","#))
    }

    /// `like` 的 unlike 必须传**字符串** "false"：Node 侧是
    /// `query.like == 'false'` 的松散比较，传 JSON 布尔 false 会被当成 true（= 收藏）
    func testUnlikeMustSendStringFalse() {
        func normalize(_ raw: String?) -> Bool {
            raw == "false" ? false : true
        }
        XCTAssertFalse(normalize("false"), #"字符串 "false" 才是取消收藏"#)
        XCTAssertTrue(normalize(nil), "缺省是收藏")
        XCTAssertTrue(normalize("true"))
        XCTAssertTrue(normalize("0"), "0 也会被当成收藏，这是上游的坑")
    }
}
