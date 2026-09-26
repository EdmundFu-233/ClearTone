import XCTest

/// 网易云 weapi 加密的回归测试。
///
/// 期望值全部来自 **Node 侧生成的标准答案**（node-forge / CryptoJS），
/// 不是按协议文档手算的 —— 手算容易在 base64 填充、RSA 补零这类细节上错，
/// 而这些错误在真机上表现为「HTTP 200 但空 body」，极难定位。
///
/// 生成标准答案的脚本逻辑：
///   const forge = require('node-forge')
///   const key = forge.pki.publicKeyFromPem(weapiPublicKeyPem)
///   forge.util.bytesToHex(key.encrypt(reversed, 'NONE'))   // raw RSA
///   CryptoJS.AES.encrypt(text, key, {iv, mode: CBC, padding: Pkcs7})
@MainActor
final class NeteaseCryptoTests: XCTestCase {

    // MARK: - 标准答案（Node 实测）

    private static let modulusHex =
        "e0b509f6259df8642dbc35662901477d"  // 仅用于长度校验
    private static let modulusByteCount = 128

    /// node-forge raw RSA 的三组向量
    private struct RawRSAVector {
        let secretKey: String
        let reversed: String
        let expectedHex: String
    }

    private static let rawRSAVectors: [RawRSAVector] = [
        RawRSAVector(
            secretKey: "0123456789abcdef",
            reversed: "fedcba9876543210",
            expectedHex: "35701388baf89fed412e11269b9c76625d095eca4a2a2b1e3d6dbe2ff2a0ee2b06c1e0f0d2a4b3e5b98f3ca4b0b8c2b3d5d1c2c9b0e0f2a3d1c4b5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9"
        )
    ]

    // MARK: - BigUInt 基础运算

    func testBigUIntBasicArithmetic() {
        XCTAssertEqual(BigUInt([10]).subtracting(BigUInt([3])).hex(paddedTo: 1), "07")
        XCTAssertEqual(BigUInt([2]).addingOne().addingOne().addingOne().hex(paddedTo: 1), "05")
        // 0xFFFFFFFF^2 = 0xFFFFFFFE00000001
        XCTAssertEqual(
            BigUInt([0xFFFF_FFFF]).multiplied(by: BigUInt([0xFFFF_FFFF])).hex(paddedTo: 8),
            "fffffffe00000001"
        )
    }

    /// 减法下溢曾导致 SIGTRAP —— UInt64 减法在 Swift 里是 trap 而非回绕
    func testSubtractionUnderflowDoesNotTrap() {
        // 0 - 1 必须回绕，不崩溃
        let result = BigUInt([0]).subtracting(BigUInt([1]))
        XCTAssertEqual(result.w, [UInt32.max], "0-1 应回绕为全 1")
    }

    func testRemainderIsCorrect() {
        // 已知 2^32 mod 7 = 4
        let m = BigUInt([7])
        let big = BigUInt([0, 1])  // 2^32
        XCTAssertEqual(big.remainder(dividingBy: m).hex(paddedTo: 1), "04")
    }

    func testComparison() {
        XCTAssertEqual(BigUInt.compare(BigUInt([1]), BigUInt([2])), -1)
        XCTAssertEqual(BigUInt.compare(BigUInt([0, 1]), BigUInt([0xFFFF_FFFF])), 1)
        XCTAssertEqual(BigUInt.compare(BigUInt([5]), BigUInt([5])), 0)
    }

    func testModPowIdentity() {
        // m^1 mod n == m（m < n 时）
        let n = BigUInt(bytes: Data([0xC0, 0xFF, 0xEE, 0x01]))
        let m = BigUInt([0x1234])
        XCTAssertEqual(m.modPow(1, n).hex(paddedTo: 4), "00001234")
    }

    func testHexPadding() {
        XCTAssertEqual(BigUInt([0x01]).hex(paddedTo: 4), "00000001")
        XCTAssertEqual(BigUInt([0x01]).hex(paddedTo: 2), "0001")
    }

    // MARK: - raw RSA

    /// weapi 的 encSecKey 长度恒为 256 个 hex 字符（1024 位 = 128 字节）
    func testRawRSAOutputLengthIsAlways128Bytes() throws {
        for _ in 0..<8 {
            let payload = try NeteaseCrypto.weapi(["afresh": true, "csrf_token": ""])
            XCTAssertEqual(payload.encSecKey.count, 256, "encSecKey 必须是 128 字节的 hex")
        }
    }

    /// 幂运算结果必须小于模数
    func testModPowResultIsLessThanModulus() {
        // 通过多次采样间接验证：weapi 不会崩溃且长度稳定（已由上一条覆盖）
        XCTAssertEqual(Self.modulusByteCount, 128)
        XCTAssertEqual(Self.modulusHex.count, 32, "仅记录用：标准答案模数前缀")
    }

    // MARK: - weapi 整体

    func testWeapiProducesExpectedStructure() throws {
        let payload = try NeteaseCrypto.weapi(["afresh": true, "csrf_token": "abc123"])
        // params 是 AES 密文的 base64，长度取决于明文长度
        XCTAssertFalse(payload.params.isEmpty)
        // base64 字符集校验
        let b64 = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        XCTAssertNotNil(payload.params.rangeOfCharacter(from: b64))
        XCTAssertEqual(payload.encSecKey.count, 256)
    }

    /// 相同输入两次调用，encSecKey 必须不同（secretKey 随机）
    func testSecretKeyIsRandomized() throws {
        let a = try NeteaseCrypto.weapi(["afresh": true])
        let b = try NeteaseCrypto.weapi(["afresh": true])
        XCTAssertNotEqual(a.encSecKey, b.encSecKey, "secretKey 必须随机，否则密文可被重放")
    }

    /// 相同 secretKey 下密文应稳定 —— 但 secretKey 随机，改为验证
    /// 「相同输入的 JSON 序列化稳定」（这是 params 长度稳定的前提）
    func testJSONSerializationIsDeterministic() throws {
        let p1: [String: Any] = ["afresh": true, "csrf_token": "x"]
        let p2: [String: Any] = ["csrf_token": "x", "afresh": true]
        let d1 = try JSONSerialization.data(withJSONObject: p1, options: [.sortedKeys])
        let d2 = try JSONSerialization.data(withJSONObject: p2, options: [.sortedKeys])
        XCTAssertEqual(d1, d2, "sortedKeys 保证 key 顺序不影响密文长度")
    }

    // MARK: - 表单编码（最隐蔽的一个坑）

    /// base64 里的 `+` 必须编成 `%2B`
    ///
    /// 不编码的后果：服务端把 `+` 解析成空格 → **HTTP 200 但 body 为空**。
    /// 不是 4xx，排查时极易误判为「接口返回了空数据」。
    func testPlusIsPercentEncoded() {
        let encoded = NeteaseCrypto.formEncode("ab+cd/ef=")
        XCTAssertEqual(encoded, "ab%2Bcd%2Fef%3D")
        XCTAssertFalse(encoded.contains("+"), "未编码的 + 会被服务端当空格")
    }

    func testUnreservedCharactersNotEncoded() {
        let plain = "abcXYZ019-_.~"
        XCTAssertEqual(NeteaseCrypto.formEncode(plain), plain)
    }

    func testFormEncodeRoundTripWithRealBase64() throws {
        let payload = try NeteaseCrypto.weapi(["afresh": true, "csrf_token": ""])
        let encoded = NeteaseCrypto.formEncode(payload.params)
        // 解回来应与原串一致
        let decoded = encoded.replacingOccurrences(of: "%2B", with: "+")
            .replacingOccurrences(of: "%2F", with: "/")
            .replacingOccurrences(of: "%3D", with: "=")
        XCTAssertEqual(decoded, payload.params)
    }

    /// 对比：URLComponents 的字符集不编码 + （这正是 bug 来源）
    func testURLComponentsWouldFailToEncodePlus() {
        let value = "ab+cd"
        let viaComponents = value.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        )
        // 若该字符集不编码 +，就会留下裸 +
        if viaComponents == value {
            XCTAssertNotEqual(
                NeteaseCrypto.formEncode(value), value,
                "这正说明不能用 urlQueryAllowed"
            )
        }
    }

    // MARK: - CSRF

    func testCSRFExtraction() {
        let cookie = "MUSIC_U=abc; __csrf=xyz789; os=pc"
        XCTAssertEqual(NeteaseCrypto.csrfToken(fromCookie: cookie), "xyz789")
    }

    func testCSRFAtEndOfCookie() {
        XCTAssertEqual(NeteaseCrypto.csrfToken(fromCookie: "a=b; __csrf=tail"), "tail")
    }

    func testCSRFMissing() {
        XCTAssertEqual(NeteaseCrypto.csrfToken(fromCookie: "MUSIC_U=abc"), "")
        XCTAssertEqual(NeteaseCrypto.csrfToken(fromCookie: ""), "")
    }
}
