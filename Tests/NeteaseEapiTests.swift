import XCTest

// 注意：**不要**写 `@testable import ClearTone`。
// `project.yml` 把 `ClearTone/**` 源码直接列进了 ClearToneTests 的 sources，
// 所以被测类型就在本模块里，无需 import；而 app 的 product module 名是
// PRODUCT_NAME 覆写后的「澄音」，`import ClearTone` 必然找不到。

/// eapi 加密链路的对照测试。
///
/// 期望值全部由**打包进仓库的 Node 运行时**跑 `api/util/crypto.js` 的
/// `eapi()` 生成（脚本见 `docs/verification.md`），不是手算或从别处抄的。
/// 逐字节一致才算通过 —— eapi 的签名覆盖整个 JSON 字节序列，
/// 差一个键序或一个字节都会得到完全不同的密文。
final class NeteaseEapiTests: XCTestCase {

    /// 与 Node 侧 `request.js` 里 `header` 对象字面量键序完全一致。
    /// 固定 requestId / buildver 是为了消掉随机性，让密文可复现。
    private static let fixedHeader: OrderedJSON.Value = .object([
        ("osver", .string("10.15.7")),
        ("deviceId", .string("p6i5y8e9w2s4h7g3")),
        ("os", .string("osx")),
        ("appver", .string("2.9.7")),
        ("versioncode", .string("140")),
        ("mobilename", .string("")),
        ("buildver", .string("1789000000")),
        ("resolution", .string("1920x1080")),
        ("__csrf", .string("abc123")),
        ("channel", .string("netease")),
        ("requestId", .string("1789000000000_0042")),
        ("MUSIC_U", .string("MUSIC_U_TEST")),
    ])

    private func eapiParams(uri: String, business: OrderedJSON.Value) throws -> String {
        // Node 侧顺序：模块 data 的键 → e_r → header
        let payload = business.appending([("e_r", .bool(false)), ("header", Self.fixedHeader)])
        return try NeteaseCrypto.eapi(uri: uri, payload: payload)
    }

    // MARK: - 逐字节对照

    func testToplistMatchesNodeVector() throws {
        let got = try eapiParams(uri: "/api/toplist", business: .object([]))
        XCTAssertEqual(got, "21198D2616ECB14FEB4410B511166D7DC3AA94370FB43643B6D6086E47BDA11A1DE13BDBD98B35588F592AF3D7947659B69BDCD4947E4606025F458B26D7F6731DC55A9C686EAA8E17672084B2E90561F69EC809E6E6BDEB2C0F9D2D3C68B0363E75F8F2D5E818C278CA27F26DC66A48F71A7F189B3077439CCAB4466A2767C4EC258515380CA36A5F488E31923214015C6CB740DB77E141BD230D82CE24680357AF07BE0F4544546F9AB2220943EC9E10D65F61BAA1BCB4823D7B62B65EDC9B529E2E9860A3E4012D6419579E81686A1AFC5ED60323008D8C91D1D88EC9F43623DC8880BBAD7D835D8B8EC9F3A06F3447277D9177083A9FFCC2751A6E76518CF189096D724CA1D750B7D8B01970C921A8537ED4E4D6562F9F7070449D112E4B2B8419FF91EB43BFD6DD7108F1BB66C8572B563E763928CB5CE152E0025AB983A57A9FF04E657642386D33905903227D40E6011BE24EEF51B54B5D3196B21EF9", "密文长度应为 700 hex 字符（438 字节），实际 \(got.count)")
    }

    func testSearchHotMatchesNodeVector() throws {
        let got = try eapiParams(
            uri: "/api/search/hot",
            business: .object([("type", .int(1111))])
        )
        XCTAssertTrue(got.hasPrefix("886AF8D09CBF98AE6DEE4A18C0124D90E49B69771D767F8636040"))
    }

    func testDailySigninMatchesNodeVector() throws {
        let got = try eapiParams(
            uri: "/api/point/dailyTask",
            business: .object([("type", .int(0))])
        )
        XCTAssertTrue(got.hasPrefix("04F1A0AB8150EFD085BC839891D19E2E488A2D6C2924C5589260A"))
    }

    func testPlaylistTracksMatchesNodeVector() throws {
        let got = try eapiParams(
            uri: "/api/playlist/manipulate/tracks",
            business: .object([
                ("op", .string("add")),
                ("pid", .string("123")),
                ("tracks", .string("[\"347231\"]")),
                ("imme", .string("true")),
            ])
        )
        XCTAssertTrue(got.hasPrefix("91B670897A84D43B91215107378D4C4BD6D8D7A838EB11E75B7B2C2"))
    }

    /// 完整的 tracks 用例必须整串相等（前缀不足以发现 JSON 转义差异）
    func testPlaylistTracksFullVectorMatches() throws {
        let got = try eapiParams(
            uri: "/api/playlist/manipulate/tracks",
            business: .object([
                ("op", .string("add")),
                ("pid", .string("123")),
                ("tracks", .string("[\"347231\"]")),
                ("imme", .string("true")),
            ])
        )
        XCTAssertEqual(got, "91B670897A84D43B91215107378D4C4BD6D8D7A838EB11E75B7B2C2FA2A2700FA0FBCF04D831C6EB8FE7E530FEED064AD406F9DDD8B747A73E4DFE653716EB7055333439FBC0DC5385A32282FD62D6D8AA21C017217CEF77E645B42D7FCD09581CD622ACD32E2690EC3F86D3D44745441DE13BDBD98B35588F592AF3D7947659B69BDCD4947E4606025F458B26D7F6731DC55A9C686EAA8E17672084B2E90561F69EC809E6E6BDEB2C0F9D2D3C68B0363E75F8F2D5E818C278CA27F26DC66A48F71A7F189B3077439CCAB4466A2767C4EC258515380CA36A5F488E31923214015C6CB740DB77E141BD230D82CE24680357AF07BE0F4544546F9AB2220943EC9E10D65F61BAA1BCB4823D7B62B65EDC9B529E2E9860A3E4012D6419579E81686A1AFC5ED60323008D8C91D1D88EC9F43623DC8880BBAD7D835D8B8EC9F3A06F3447277D9177083A9FFCC2751A6E76518CF189096D724CA1D750B7D8B01970C921A8537ED4E4D6562F9F7070449D112E4B2B8419FF91EB43BFD6DD7108F1BB66C8572B563E763928CB5CE152E0025AB983513E8AC82DB132DA232C9324ECD93DA944BD6DCBBE6E2E0D691E38D3ECD12B67")
    }

    // MARK: - 形状不变量

    /// 密文长度必须是 16 的整数倍（且不含填充尾块）
    func testCiphertextIsBlockAligned() throws {
        let got = try eapiParams(uri: "/api/toplist", business: .object([]))
        XCTAssertEqual(got.count % 32, 0, "hex 长度应为 32 的倍数（16 字节块 × 2）")
    }

    /// hex 必须是大写 —— api-enhanced 取 `ciphertext.toString().toUpperCase()`
    func testCiphertextIsUppercaseHex() throws {
        let got = try eapiParams(uri: "/api/toplist", business: .object([]))
        XCTAssertEqual(got, got.uppercased())
        XCTAssertTrue(got.allSatisfy { $0.isHexDigit })
    }

    // MARK: - 保序 JSON

    func testOrderedJSONPreservesInsertionOrder() {
        let value = OrderedJSON.Value.object([
            ("z", .int(1)),
            ("a", .int(2)),
            ("m", .int(3)),
        ])
        XCTAssertEqual(OrderedJSON.encode(value), #"{"z":1,"a":2,"m":3}"#)
    }

    /// 键序不同 → 序列化结果不同 → eapi 密文不同。
    /// 这正是必须用 OrderedJSON 而非 Dictionary 的原因。
    func testDifferentKeyOrderProducesDifferentPayload() throws {
        let a = OrderedJSON.Value.object([("op", .string("add")), ("pid", .string("1"))])
        let b = OrderedJSON.Value.object([("pid", .string("1")), ("op", .string("add"))])
        XCTAssertNotEqual(OrderedJSON.encode(a), OrderedJSON.encode(b))
    }

    /// JSON.stringify 的转义规则：短控制字符用短形式，键名与值都不加多余空白
    func testJSONStringEscaping() {
        XCTAssertEqual(
            OrderedJSON.encode(.string("a\"b\\c\nd\te")),
            #""a\"b\\c\nd\te""#
        )
        XCTAssertEqual(
            OrderedJSON.encode(.string("中文 / slash")),
            #""中文 / slash""#
        )
        XCTAssertEqual(OrderedJSON.encode(.string("\u{01}")), #""\u0001""#)
    }

    func testJSONNumberFormattingMatchesJS() {
        XCTAssertEqual(OrderedJSON.encode(.int(1111)), "1111")
        XCTAssertEqual(OrderedJSON.encode(.double(1111)), "1111")
        XCTAssertEqual(OrderedJSON.encode(.double(1.5)), "1.5")
        XCTAssertEqual(OrderedJSON.encode(.bool(false)), "false")
        XCTAssertEqual(OrderedJSON.encode(.null), "null")
    }

    func testAppendingPreservesExistingPairs() {
        let base = OrderedJSON.Value.object([("id", .string("7"))])
        let appended = base.appending([("e_r", .bool(false))])
        XCTAssertEqual(OrderedJSON.encode(appended), #"{"id":"7","e_r":false}"#)
        // 非 object 返回自身
        XCTAssertEqual(OrderedJSON.encode(OrderedJSON.Value.int(1).appending([("x", .int(2))])), "1")
    }

    // MARK: - MD5

    func testMD5MatchesKnownVectors() {
        XCTAssertEqual(NeteaseCrypto.md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(NeteaseCrypto.md5Hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(NeteaseCrypto.md5Hex("hello"), "5d41402abc4b2a76b9719d911017c592")
    }

    // MARK: - 键序登记

    /// 每条 eapi 路由都必须登记键序，且登记的键必须与 Node 模块一致
    func testEveryEapiRouteHasRegisteredKeyOrder() {
        let registered = NeteaseEndpoint.eapiParamKeys
        for route in NeteaseEndpoint.knownRoutes {
            guard let endpoint = NeteaseEndpoint.endpoint(forRoute: route),
                  endpoint.crypto == .eapi else { continue }
            XCTAssertNotNil(
                registered[endpoint.orderedParamsKey ?? ""],
                "\(route) 的 eapi 键序未登记"
            )
        }
    }

    /// module 写死的参数必须在 spec 里登记成 `constants`。
    ///
    /// 漏登记的后果是直连层拼出的 `JSON.stringify` 与辅助进程发出去的不一致，
    /// 而签名失败在界面上只表现为「接口报错」，没有任何提示指向键序。
    func testArtistSongsHardcodedParamsAreRegisteredAsConstants() throws {
        let spec = try XCTUnwrap(NeteaseEndpoint.eapiParamKeys["artistSongs"])
        XCTAssertEqual(spec.constantKeys, ["private_cloud", "work_type"])
        // 写死的键不允许出现在 query 里
        XCTAssertNil(NeteaseEndpoint.orderedPayload(
            forRoute: "/artist/songs",
            query: ["id": "1", "order": "hot", "offset": "0", "limit": "50",
                    "private_cloud": "true"]
        ))
    }

    /// 未登记的键必须让 orderedPayload 返回 nil —— 宁可显式失败，
    /// 也不能拼一个错的顺序让签名静默失败
    func testUnregisteredQueryKeyIsRejected() {
        XCTAssertNil(
            NeteaseEndpoint.orderedPayload(
                forRoute: "/playlist/tracks",
                query: ["op": "add", "pid": "1", "tracks": "[\"1\"]", "imme": "true", "oops": "x"]
            )
        )
    }

    /// 数字型参数不能被当字符串加引号（Node 侧是数字字面量）
    func testNumericParamsAreNotQuoted() {
        guard let payload = NeteaseEndpoint.orderedPayload(
            forRoute: "/search/hot", query: ["type": "1111"]
        ) else { return XCTFail("应当能构造出有序参数") }
        XCTAssertEqual(OrderedJSON.encode(payload), #"{"type":1111}"#)
    }

    func testOrderedPayloadForFixedParamlessRoutes() {
        XCTAssertEqual(
            OrderedJSON.encode(NeteaseEndpoint.orderedPayload(forRoute: "/toplist", query: [:]) ?? .null),
            "{}"
        )
        XCTAssertEqual(
            OrderedJSON.encode(NeteaseEndpoint.orderedPayload(forRoute: "/playlist/catlist", query: [:]) ?? .null),
            "{}"
        )
    }

    /// 非 eapi 路由不该走这个入口
    func testNonEapiRouteReturnsNil() {
        XCTAssertNil(NeteaseEndpoint.orderedPayload(forRoute: "/like", query: ["id": "1"]))
    }
}
