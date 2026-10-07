import XCTest
import CryptoKit
@testable import ClearTone

final class NeteaseXeapiTests: XCTestCase {
    /// 期望值由仓库打包 Node 的 util/crypto.js 产生；固定随机数与 X25519 私钥。
    func testRequestMatchesBundledNodeByteForByte() throws {
        let key = NeteaseXeapi.PublicKey(publicKey: "eaYx7t4b+cmPEgMs3q3Q56B5OY/HhriMyEbsia+FpRo=", version: "1", sk: "fixture-sk")
        let payload = OrderedJSON.Value.object([("ids", .string("[347230]")), ("level", .string("exhigh")), ("encodeType", .string("flac"))])
        let result = try NeteaseXeapi.encrypt(payload: payload, key: key,
            dynamicKey: Data(repeating: 0x21, count: 16), mask: Data((0..<16).map { UInt8($0 + 0x10) }),
            privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data((1...32).map(UInt8.init))),
            nonce: AES.GCM.Nonce(data: Data(repeating: 0x42, count: 12)))
        XCTAssertEqual(result["B"], "yEchxedJieYF3fOtMv0ehYv77W4LC0L+SDag+EqqCZujxzwN5j+Xye5rq1vDlxO2nio2/ENrXSFExF0gdn94GTewIjt7L5gMObEnk2Un5dZ7XMLN/KbOUJ0XS6w5yfdmulZ+8RknajSlS3tzBdiCpKJcsmngG4Kr3ylasjnsdTqZ+9wAOGpgHu6oaKKdtOnadt5s5SWB/jz3+6DLauLA5omq1HKpgnJkJhPAqMEW1RI=")
        XCTAssertEqual(result["S"], "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHxCQkJCQkJCQkJCQkLAC4ONIhZLJSPmOb7tRt0FBn53c1LYWl++TRuxz/vTcZD/xoklbYApCLgpwBkRymMV4PHXj2vnmfbfgw==")
        XCTAssertEqual(result["R"], "a590Ju77tpVWsMMqYB/diQ==")
    }
    func testKeyRegistrationSignatureMatchesNode() {
        XCTAssertEqual(NeteaseXeapi.sign(timestamp: "1700000000000", nonce: "1234567890123456"), "AfwKXk83sQ/wAKzoswSsn7/DgRvQ6zfI4O5eOSKnkIA=")
    }
    func testDecryptGzippedResponseAndRejectCorruptGzip() throws {
        let gzip = Data(base64Encoded: "H4sIAAAAAAAAE6tWSs5PSVWyMjIwqAUAVAOW6gwAAAA=")!
        let cipher = try NeteaseXeapi.aes(gzip, key: Data("e82ckenh8dichen8".utf8))
        let decrypted = try NeteaseXeapi.aes(cipher, key: Data("e82ckenh8dichen8".utf8), decrypt: true)
        XCTAssertEqual(try NeteaseXeapi.inflateIfNeeded(decrypted), Data("{\"code\":200}".utf8))
        XCTAssertThrowsError(try NeteaseXeapi.inflateIfNeeded(Data([0x1f, 0x8b, 0])))
    }
    func testInvalidPublicKeyRejected() throws {
        let key = NeteaseXeapi.PublicKey(publicKey: "invalid", version: "1", sk: "fixture")
        XCTAssertThrowsError(try NeteaseXeapi.encrypt(payload: .object([]), key: key,
            dynamicKey: Data(repeating: 0, count: 16), mask: Data(repeating: 0, count: 16),
            privateKey: Curve25519.KeyAgreement.PrivateKey(), nonce: AES.GCM.Nonce()))
    }

    /// 设备标识必须跨启动稳定：xeapi 的 key 注册、`x-deviceid` 头、
    /// Cookie 里的 `deviceId` 用的都是它，每次启动换一个等于
    /// 「同一台设备每次来都换了身份」。
    func testDeviceIDIsReusedWhenAlreadyStored() {
        let stored = "ABCDEF0123456789ABCDEF0123456789"
        XCTAssertEqual(NeteaseXeapi.resolveDeviceID(stored), stored, "合法的存值必须原样复用")
        for bad in [nil, "short", String(repeating: "z", count: 32), String(repeating: "g", count: 32)] {
            let fresh = NeteaseXeapi.resolveDeviceID(bad)
            XCTAssertEqual(fresh.count, 32, "形状不对的存值 \(bad ?? "nil") 应当换掉")
            XCTAssertTrue(fresh.allSatisfy(\.isHexDigit))
        }
    }

    /// 早先是 `cookie + "; os=android; ..."` 硬拼 —— 调用方那份里已经带
    /// `os=` / `deviceId=` 时会出现两个同名 cookie，服务端取前一个还是后一个
    /// 完全看运气，也就是说可能拿到 iOS 身份的响应。
    func testMergeCookieOverridesDuplicatesAndDropsSetCookieAttributes() {
        let merged = NeteaseXeapi.mergeCookie(
            "MUSIC_U=abc==; os=ios; DeviceId=old; Path=/; HttpOnly; SameSite=None; ; Expires=Wed, 21 Oct 2026 07:28:00 GMT",
            deviceID: "NEWDEVICEID0123456789NEWDEVICEI", buildver: "1700000000"
        )
        let names = merged.split(separator: ";").map {
            $0.split(separator: "=", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(Set(names).count, names.count, "同名 cookie 只能出现一次：\(merged)")
        XCTAssertTrue(names.contains("MUSIC_U"), "登录态必须带过去：\(merged)")
        XCTAssertFalse(names.contains("Path"))
        XCTAssertFalse(names.contains("HttpOnly"))
        XCTAssertFalse(names.contains("SameSite"))
        XCTAssertFalse(names.contains("Expires"))
        XCTAssertTrue(merged.contains("os=android"), "xeapi 冒充 Android，调用方的 os=ios 必须被盖掉")
        XCTAssertFalse(merged.contains("os=ios"))
        XCTAssertTrue(merged.contains("deviceId=NEWDEVICEID0123456789NEWDEVICEI"))
        XCTAssertTrue(merged.contains("sDeviceId=NEWDEVICEID0123456789NEWDEVICEI"))
        XCTAssertFalse(merged.contains("DeviceId=old"))
        XCTAssertTrue(merged.contains("buildver=1700000000"))
        XCTAssertTrue(merged.contains("appver=9.1.65"))
        XCTAssertTrue(merged.contains("osver=16"))
    }

    /// 空 cookie 也要产出完整的固定字段，不能拼出 `" ; os=android"` 这种前导分号
    func testMergeCookieWithoutIncomingCookieIsWellFormed() {
        let merged = NeteaseXeapi.mergeCookie(nil, deviceID: "D", buildver: "1")
        XCTAssertTrue(merged.hasPrefix("os="), merged)
        XCTAssertFalse(merged.contains("; ;"))
        XCTAssertEqual(merged.split(separator: ";").count, 6, "六个固定字段，一个不多一个不少：\(merged)")
    }
}
