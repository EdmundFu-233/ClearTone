import XCTest
@testable import ClearTone

final class NeteaseMobileRouteTests: XCTestCase {
    func testQRKeyUsesActualQrcodeRouteAndFixedType() throws {
        let request = try NeteaseMobileRoute.make("/login/qr/key", query: ["randomCNIP": "true"])
        XCTAssertEqual(request.path, "/api/login/qrcode/unikey")
        XCTAssertEqual(request.crypto, .eapi)
        XCTAssertEqual(OrderedJSON.encode(request.payload), "{\"type\":3}")
    }
    func testQRCheckDiscardsHelperOnlyOptions() throws {
        let request = try NeteaseMobileRoute.make("/login/qr/check", query: ["key": "fixture", "timestamp": "123", "randomCNIP": "true"])
        XCTAssertEqual(request.path, "/api/login/qrcode/client/login")
        XCTAssertEqual(OrderedJSON.encode(request.payload), "{\"key\":\"fixture\",\"type\":3}")
    }
    func testQRURLIsFirstPartyAndEscapesKey() throws {
        let url = try NeteaseMobileRoute.qrURL(key: "a&b")
        XCTAssertEqual(url.host, "music.163.com")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "codekey", value: "a&b")])
    }
    func testSearchRenamesKeywordsAndCarriesPageOffset() throws {
        let request = try NeteaseMobileRoute.make("/cloudsearch", query: ["keywords": "周杰伦", "type": "1000", "offset": "60", "limit": "30"])
        XCTAssertEqual(OrderedJSON.encode(request.payload), "{\"s\":\"周杰伦\",\"type\":\"1000\",\"limit\":\"30\",\"offset\":\"60\",\"total\":true}")
        XCTAssertEqual(request.crypto, .eapi)
    }
    func testSongDetailConvertsIDsIntoNodeCField() throws {
        let request = try NeteaseMobileRoute.make("/song/detail", query: ["ids": "123, 456"])
        XCTAssertEqual(OrderedJSON.encode(request.payload), "{\"c\":\"[{\\\"id\\\":123},{\\\"id\\\":456}]\"}")
        XCTAssertThrowsError(try NeteaseMobileRoute.make("/song/detail", query: ["ids": "1],attack"]))
    }
    func testPlaylistDetailFixedValuesAndAlbumPath() throws {
        let request = try NeteaseMobileRoute.make("/playlist/detail", query: ["id": "12"])
        XCTAssertEqual(OrderedJSON.encode(request.payload), "{\"id\":\"12\",\"n\":100000,\"s\":8}")
        let album = try NeteaseMobileRoute.make("/album", query: ["id": "34"])
        XCTAssertEqual(album.path, "/api/v1/album/34")
        XCTAssertEqual(OrderedJSON.encode(album.payload), "{}")
    }
    func testLikeUsesBooleanAndUpstreamNames() throws {
        let request = try NeteaseMobileRoute.make("/song/like", query: ["id": "1", "uid": "2", "like": "false"])
        XCTAssertEqual(OrderedJSON.encode(request.payload), "{\"trackId\":\"1\",\"userid\":\"2\",\"like\":false}")
    }
    func testPlaylistWriteSerializesStringIDsAndFixedImme() throws {
        let request = try NeteaseMobileRoute.make("/playlist/tracks", query: ["pid": "1", "op": "add", "tracks": "2,3"])
        XCTAssertEqual(OrderedJSON.encode(request.payload), "{\"op\":\"add\",\"pid\":\"1\",\"trackIds\":\"[\\\"2\\\",\\\"3\\\"]\",\"imme\":\"true\"}")
    }
    func testLyricAddsTypedFixedDefaults() throws {
        let request = try NeteaseMobileRoute.make("/lyric/new", query: ["id": "1"])
        XCTAssertEqual(OrderedJSON.encode(request.payload), "{\"id\":\"1\",\"cp\":false,\"tv\":0,\"lv\":0,\"rv\":0,\"kv\":0,\"yv\":0,\"ytv\":0,\"yrv\":0}")
    }
    func testCommentUnlikeResolvesPathAndResourcePrefix() throws {
        let request = try NeteaseMobileRoute.make("/comment/like", query: ["id": "1", "cid": "2", "type": "0", "t": "0"])
        XCTAssertEqual(request.path, "/api/v1/comment/unlike")
        XCTAssertEqual(OrderedJSON.encode(request.payload), "{\"threadId\":\"R_SO_4_1\",\"commentId\":\"2\"}")
    }
    func testXeapiPlaybackHasNoSilentCryptoDowngrade() throws {
        let request = try NeteaseMobileRoute.make("/song/url/v1", query: ["id": "347230", "level": "exhigh"])
        XCTAssertEqual(request.crypto, .xeapi)
        XCTAssertEqual(OrderedJSON.encode(request.payload), "{\"ids\":\"[347230]\",\"level\":\"exhigh\",\"encodeType\":\"flac\"}")
        XCTAssertThrowsError(try NeteaseMobileRoute.make("/song/url/match", query: ["id": "1"]))
    }
    /// iOS 的搜索联想走 `/search/suggest`，而它曾**没有**适配分支 ——
    /// 端点表有登记、provider 也在调，`make` 却抛「暂未适配」，
    /// 界面表现是搜索框下面永远空着，一行日志都没有。
    func testSearchSuggestIsAdaptedWithUpstreamSKey() throws {
        let request = try NeteaseMobileRoute.make("/search/suggest", query: ["keywords": "周杰伦"])
        XCTAssertEqual(request.path, "/api/search/suggest/web")
        XCTAssertEqual(request.crypto, .weapi)
        // search_suggest.js: data 只有 `{ s: query.keywords }`
        XCTAssertEqual(OrderedJSON.encode(request.payload), "{\"s\":\"周杰伦\"}")
    }

    /// `/logout` 曾被标成 `.plain`。logout.js 是 `createOption(query)`
    /// —— 裸调用 = eapi，且 data 恒为 `{}`（认证只靠 cookie）。
    /// 按错误的 `.plain` 直连会得到一个上游根本不认的签名。
    func testLogoutUsesEapiAndEmptyBody() throws {
        let request = try NeteaseMobileRoute.make("/logout", query: [:])
        XCTAssertEqual(request.path, "/api/logout")
        XCTAssertEqual(request.crypto, .eapi)
        XCTAssertEqual(OrderedJSON.encode(request.payload), "{}")
    }

    /// `.plain` 分支原先用 `String(describing:)` 把 JSON 值转成表单字符串：
    /// `JSONSerialization` 给回来的是 `NSNumber`，布尔会被描述成 `"1"`/`"0"`
    /// （Node 的 `querystring` 发的是 `"true"`/`"false"`），数组会变成
    /// 多行的 `(1, 2)`。两种都会让对端收下错的 body，
    /// 而响应只说「参数不对」，不指向任何一行代码。
    func testPlainFormValuesKeepNodeScalarSpelling() throws {
        let json = #"{"type":"qr","n":1111,"on":true,"off":false,"text":"a=b"}"#
        let payload = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let values = try NeteaseDirectTransport.formValues(from: XCTUnwrap(payload))
        XCTAssertEqual(values["type"], "qr")
        XCTAssertEqual(values["n"], "1111")
        XCTAssertEqual(values["on"], "true")
        XCTAssertEqual(values["off"], "false")
        XCTAssertEqual(values["text"], "a=b")

        // 标量以外的类型必须显式失败，不能拼出垃圾
        let nested = try JSONSerialization.jsonObject(with: Data(#"{"ids":[1,2]}"#.utf8)) as? [String: Any]
        XCTAssertThrowsError(try NeteaseDirectTransport.formValues(from: XCTUnwrap(nested)))
    }

    func testUnadaptedRouteFailsRatherThanForwardingWrongParams() {
        XCTAssertThrowsError(try NeteaseMobileRoute.make("/unknown", query: [:]))
        XCTAssertThrowsError(try NeteaseMobileRoute.make("/playlist/subscribe", query: ["id": "1", "t": "1"]))
    }
}
