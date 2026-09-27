import Foundation
import CommonCrypto

/// 网易云 weapi / eapi 加密的纯 Swift 实现。
///
/// ## 当前状态：**已保留，但生产路径不调用它**
///
/// macOS 版通过本地 Node.js 辅助进程（api-enhanced）访问网易云，加密由
/// `util/crypto.js` 完成。`ClearToneiOS` target 已移除，本文件目前没有生产调用方；
/// 保留理由见 `NeteaseDirectTransport.swift` 顶部的说明，简言之：
/// 这是唯一一份不依赖 Node 的加密实现，且已逐字节验证。
///
/// 本文件的每一步都用 Node 侧（node-forge / CryptoJS）生成的标准答案
/// 逐字节校验过，验证过程见 `docs/optimization-plan.md`。
///
/// ## 协议要点（三处决定实现方式）
///
/// 1. **双重 AES-CBC**：内层输出 base64 字符串，外层加密的是这个 base64
///    *字符串的 UTF-8 字节*，不是内层密文的原始字节。
/// 2. **raw RSA，零 padding**：api-enhanced 用 `forgePublicKey.encrypt(str,'NONE')`，
///    而 node-forge 在 `'NONE'` 分支里 `scheme.encode` 是恒等函数。
///    所以 `Security.framework` 做不到（只支持 PKCS1v15/OAEP 填充），
///    必须手写大整数模幂。
/// 3. **表单编码要对标 `URLSearchParams`**：base64 里的 `+` 必须编成 `%2B`，
///    否则服务端把 `+` 解析成空格 → **HTTP 200 但 body 为空**（不是 4xx，
///    极具迷惑性）。
public enum NeteaseCrypto {

    // MARK: - 常量

    private static let presetKey = "0CoJUm6Qyw8W8jud"
    private static let iv = "0102030405060708"
    private static let base62 = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    /// weapi 公钥（1024 位 RSA，e = 65537）
    private static let publicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB
    -----END PUBLIC KEY-----
    """

    /// 模数缓存（解析 DER 只需一次）
    private static let modulus: BigUInt? = {
        let body = publicKeyPEM
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in !line.hasPrefix("-----") && !line.isEmpty }
        guard let body else { return nil }
        guard let der = Data(base64Encoded: body) else { return nil }
        guard let n = extractModulus(fromDER: der) else { return nil }
        return BigUInt(bytes: n)
    }()

    // MARK: - 对外接口

    public struct WeapiPayload {
        public let params: String
        public let encSecKey: String
    }

    /// 构造 weapi 请求体参数
    public static func weapi(_ object: [String: Any]) throws -> WeapiPayload {
        guard let modulus else { throw CryptoError.modulusUnavailable }

        // JSON 必须紧凑（无空格），与 JSON.stringify 一致
        let jsonData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let text = String(decoding: jsonData, as: UTF8.self)

        // 内层：AES-CBC(fixedKey) → base64 字符串
        guard let inner = aesCBCEncrypt(Data(text.utf8), key: presetKey, iv: iv) else {
            throw CryptoError.encryptionFailed
        }
        let innerBase64 = inner.base64EncodedString()

        // 外层：AES-CBC(随机 secretKey)，输入是内层 base64 字符串的 UTF-8 字节
        let secretKey = randomSecretKey()
        guard let outer = aesCBCEncrypt(Data(innerBase64.utf8), key: secretKey, iv: iv) else {
            throw CryptoError.encryptionFailed
        }
        let params = outer.base64EncodedString()

        // raw RSA(reverse(secretKey))
        let reversed = String(secretKey.reversed())
        let ciphertext = BigUInt(bytes: Data(reversed.utf8)).modPow(65537, modulus)
        let encSecKey = ciphertext.hex(paddedTo: 128)

        return WeapiPayload(params: params, encSecKey: encSecKey)
    }

    /// 表单编码：等价于 Node 的 `URLSearchParams.toString()`
    ///
    /// 不能用 `URLComponents.urlQueryAllowed` —— 它的字符集不包含 `+`，
    /// 编码后的 base64 里的 `+` 会原样送出，服务端按空格解析。
    public static func formEncode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    public static func csrfToken(fromCookie cookie: String) -> String {
        guard let range = cookie.range(of: "__csrf=") else { return "" }
        let tail = cookie[range.upperBound...]
        return String(tail[..<(tail.firstIndex(of: ";") ?? tail.endIndex)])
    }

    // MARK: - eapi

    /// eapi 固定密钥（16 字节 → AES-128）
    private static let eapiKey = "e82ckenh8dichen8"
    /// eapi 签名里夹在参数两侧的固定盐
    private static let eapiSalt = "36cd479b6b5"

    /// 构造 eapi 请求体参数。
    ///
    /// 步骤（逐行对标 `util/crypto.js` 的 `eapi()`）：
    /// 1. `text = JSON.stringify(payload)` —— 参与签名，**键序敏感**
    /// 2. `digest = md5("nobody" + uri + "use" + text + "md5forencrypt")`
    /// 3. `data = uri + "-盐-" + text + "-盐-" + digest`
    /// 4. `params = AES-128-ECB(data, eapiKey)` 的密文，**大写 hex**
    ///
    /// ## 第 4 步的两个坑
    ///
    /// api-enhanced 取的是 `encrypted.ciphertext` 而非 `encrypted.toString()`，
    /// 也就是**不含 PKCS#7 填充尾块**的纯密文 —— 所以这里手动填充、
    /// 再用无填充模式加密，输出长度恰好是原文长度向上取整到 16 的倍数。
    ///
    /// 另外 hex 是**大写**（`aesEncrypt` 里的 `.toUpperCase()`），
    /// 小写会被服务端判为签名不匹配。
    public static func eapi(uri: String, payload: OrderedJSON.Value) throws -> String {
        let text = OrderedJSON.encode(payload)
        let message = "nobody\(uri)use\(text)md5forencrypt"
        let digest = md5Hex(message)
        let plain = "\(uri)-\(eapiSalt)-\(text)-\(eapiSalt)-\(digest)"
        guard let ciphertext = aesECBEncryptPadded(Data(plain.utf8), key: eapiKey) else {
            throw CryptoError.encryptionFailed
        }
        var hex = ""
        hex.reserveCapacity(ciphertext.count * 2)
        for byte in ciphertext {
            hex += String(format: "%02X", byte)
        }
        return hex
    }

    /// eapi 的 `data.header`。键序与 `util/request.js` 里的对象字面量严格一致，
    /// 且值为 `undefined` 的键必须整个省略（`JSON.stringify` 会丢弃它们）。
    ///
    /// 顺序：osver · deviceId · os · appver · versioncode · mobilename ·
    /// buildver · resolution · __csrf · channel · requestId，然后按需追加
    /// MUSIC_U / MUSIC_A / X-antiCheatToken / NMTID。
    public static func eapiHeader(
        os: String,
        osver: String,
        appver: String,
        versioncode: String,
        deviceId: String,
        resolution: String,
        buildver: String,
        channel: String?,
        csrf: String,
        musicU: String?,
        musicA: String?,
        antiCheatToken: String? = nil,
        nmtid: String? = nil
    ) -> OrderedJSON.Value {
        var pairs: [(String, OrderedJSON.Value)] = [
            ("osver", .string(osver)),
            ("deviceId", .string(deviceId)),
            ("os", .string(os)),
            ("appver", .string(appver)),
            ("versioncode", .string(versioncode)),
            ("mobilename", .string("")),
            ("buildver", .string(buildver)),
            ("resolution", .string(resolution)),
            ("__csrf", .string(csrf)),
        ]
        if let channel, !channel.isEmpty { pairs.append(("channel", .string(channel))) }
        pairs.append(("requestId", .string(eapiRequestID())))
        if let musicU, !musicU.isEmpty { pairs.append(("MUSIC_U", .string(musicU))) }
        if let musicA, !musicA.isEmpty { pairs.append(("MUSIC_A", .string(musicA))) }
        if let antiCheatToken, !antiCheatToken.isEmpty {
            pairs.append(("X-antiCheatToken", .string(antiCheatToken)))
        }
        if let nmtid, !nmtid.isEmpty { pairs.append(("NMTID", .string(nmtid))) }
        return .object(pairs)
    }

    /// 对标 `generateRequestId()`：`Date.now()` + `_` + 4 位零填充随机数
    private static func eapiRequestID() -> String {
        let stamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let suffix = String(format: "%04d", Int.random(in: 0...999))
        return "\(stamp)_\(suffix)"
    }

    /// 对标 `now().toString().substr(0, 10)`：毫秒时间戳的前 10 位
    public static func eapiBuildVersion() -> String {
        let stamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        return String(stamp.prefix(10))
    }

    // MARK: - 内部

    private enum CryptoError: Error {
        case modulusUnavailable
        case encryptionFailed
    }

    private static func randomSecretKey() -> String {
        String((0..<16).map { _ in base62.randomElement()! })
    }

    /// AES-128-CBC + PKCS7
    ///
    /// 用 `NSData` 而非嵌套闭包 + `[UInt8]`：后者在 Swift 6 的排他性访问
    /// 检查下会报 overlapping accesses。
    private static func aesCBCEncrypt(_ plaintext: Data, key: String, iv: String) -> Data? {
        let k = NSData(data: Data(key.utf8))
        let v = NSData(data: Data(iv.utf8))
        let p = NSData(data: plaintext)
        let output = NSMutableData(length: plaintext.count + kCCBlockSizeAES128)!
        var written = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            k.bytes, k.length,
            v.bytes,
            p.bytes, p.length,
            output.mutableBytes, output.length,
            &written
        )
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        output.length = written
        return output as Data
    }

    /// AES-128-ECB：手动补 PKCS#7，再用无填充模式加密出纯密文。
    ///
    /// 不直接用 `kCCOptionPKCS7Padding` + `CCCryptorStatus` 的输出，
    /// 因为那会包含填充尾块，而 eapi 要的是 `ciphertext`（不含填充）。
    private static func aesECBEncryptPadded(_ plaintext: Data, key: String) -> Data? {
        let blockSize = 16
        let padCount = blockSize - (plaintext.count % blockSize)
        var padded = [UInt8](plaintext)
        padded.append(contentsOf: [UInt8](repeating: UInt8(padCount), count: padCount))

        let k = NSData(data: Data(key.utf8))
        let p = NSData(data: Data(padded))
        let output = NSMutableData(length: padded.count)!
        var written = 0
        // ECB 模式无 IV；不传 padding 选项 → 输入输出等长
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            k.bytes, k.length,
            nil,
            p.bytes, p.length,
            output.mutableBytes, output.length,
            &written
        )
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        output.length = written
        return output as Data
    }

    /// MD5，输出小写 hex（与 `CryptoJS.MD5(...).toString()` 一致）
    public static func md5Hex(_ text: String) -> String {
        let k = NSData(data: Data(text.utf8))
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        CC_MD5(k.bytes, CC_LONG(k.length), &digest)
        var hex = ""
        hex.reserveCapacity(Int(CC_MD5_DIGEST_LENGTH) * 2)
        for byte in digest {
            hex += String(format: "%02x", byte)
        }
        return hex
    }

    /// 从 SubjectPublicKeyInfo DER 提取 RSA 模数（PKCS#1 RSAPublicKey 的第一个 INTEGER）
    private static func extractModulus(fromDER der: Data) -> Data? {
        let bytes = [UInt8](der)
        // SEQUENCE 头之后第一个 0x02 即 INTEGER（模数）
        var i = 2
        while i < bytes.count && bytes[i] != 0x02 { i += 1 }
        guard i < bytes.count else { return nil }
        i += 1
        guard i < bytes.count else { return nil }

        var length = Int(bytes[i])
        i += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            length = 0
            guard count <= 4 else { return nil }
            for _ in 0..<count {
                guard i < bytes.count else { return nil }
                length = (length << 8) | Int(bytes[i])
                i += 1
            }
        }
        // 跳过正整数的前导 0x00 符号位
        if i < bytes.count && bytes[i] == 0x00 {
            i += 1
            length -= 1
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return Data(bytes[i..<(i + length)])
    }
}

// MARK: - 最小大整数

/// 够用于 raw RSA 模幂的无符号大整数（32 位字，小端，规范化）。
///
/// 只实现模幂所需：乘法、二进制长除法求余。不追求通用性能。
struct BigUInt {
    /// 小端 limbs；至少 1 个元素；0 表示为 `[0]`
    private(set) var w: [UInt32]

    init(_ limbs: [UInt32]) {
        var v = limbs
        while v.count > 1 && v.last == 0 { v.removeLast() }
        self.w = v.isEmpty ? [0] : v
    }

    static let zero = BigUInt([0])
    static let one = BigUInt([1])

    init(bytes: Data) {
        let b = [UInt8](bytes)
        var limbs: [UInt32] = []
        var i = b.count
        while i > 0 {
            let start = max(0, i - 4)
            var value: UInt32 = 0
            var shift: UInt32 = 0
            for j in (start..<i).reversed() {
                value |= UInt32(b[j]) << shift
                shift += 8
            }
            limbs.append(value)
            i -= 4
        }
        self.init(limbs)
    }

    /// 最高有效位位置（0-based）
    var bitCount: Int {
        guard let top = w.last, top != 0 else { return 0 }
        return (w.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 32
        guard limb < w.count else { return false }
        return (w[limb] >> UInt32(index % 32)) & 1 == 1
    }

    func shiftedLeftByOne() -> BigUInt {
        var out = [UInt32](repeating: 0, count: w.count + 1)
        var carry: UInt32 = 0
        for i in 0..<w.count {
            out[i] = (w[i] << 1) | carry
            carry = w[i] >> 31
        }
        out[w.count] = carry
        return BigUInt(out)
    }

    func addingOne() -> BigUInt {
        var out = w
        var i = 0
        while i < out.count {
            out[i] = out[i] &+ 1
            if out[i] != 0 { break }
            i += 1
        }
        if i == out.count { out.append(1) }
        return BigUInt(out)
    }

    static func compare(_ a: BigUInt, _ b: BigUInt) -> Int {
        if a.w.count != b.w.count { return a.w.count < b.w.count ? -1 : 1 }
        var i = a.w.count - 1
        while i >= 0 {
            if a.w[i] != b.w[i] { return a.w[i] < b.w[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    /// 要求 `self >= other`
    func subtracting(_ other: BigUInt) -> BigUInt {
        var out = w
        var borrow: UInt64 = 0
        for i in 0..<out.count {
            let y = i < other.w.count ? UInt64(other.w[i]) : 0
            let x = UInt64(out[i])
            if x >= y + borrow {
                out[i] = UInt32(x - y - borrow)
                borrow = 0
            } else {
                // 必须用 &- :UInt64 减法下溢在 Swift 里是 trap,会 SIGTRAP
                out[i] = UInt32((x &- y &- borrow) & 0xFFFF_FFFF)
                borrow = 1
            }
        }
        return BigUInt(out)
    }

    /// schoolbook 乘法
    func multiplied(by other: BigUInt) -> BigUInt {
        if w == [0] || other.w == [0] { return .zero }
        var product = [UInt64](repeating: 0, count: w.count + other.w.count)
        for i in 0..<w.count {
            let a = UInt64(w[i])
            if a == 0 { continue }
            var carry: UInt64 = 0
            for j in 0..<other.w.count {
                let t = product[i + j] + a * UInt64(other.w[j]) + carry
                product[i + j] = t & 0xFFFF_FFFF
                carry = t >> 32
            }
            var k = i + other.w.count
            while carry != 0 && k < product.count {
                let t = product[k] + carry
                product[k] = t & 0xFFFF_FFFF
                carry = t >> 32
                k += 1
            }
        }
        return BigUInt(product.map { UInt32($0) })
    }

    /// 二进制长除法求余
    func remainder(dividingBy m: BigUInt) -> BigUInt {
        if BigUInt.compare(self, m) < 0 { return self }
        var r = BigUInt.zero
        var i = bitCount - 1
        while i >= 0 {
            r = r.shiftedLeftByOne()
            if bit(i) { r = r.addingOne() }
            if BigUInt.compare(r, m) >= 0 { r = r.subtracting(m) }
            i -= 1
        }
        return r
    }

    func multiplied(_ other: BigUInt, modulo m: BigUInt) -> BigUInt {
        multiplied(by: other).remainder(dividingBy: m)
    }

    /// 模幂（square-and-multiply）。e = 65537 只需 17 次平方。
    func modPow(_ exponent: Int, _ modulus: BigUInt) -> BigUInt {
        var result = BigUInt.one
        var base = self
        var e = exponent
        while e > 0 {
            if e & 1 == 1 { result = result.multiplied(base, modulo: modulus) }
            e >>= 1
            if e > 0 { base = base.multiplied(base, modulo: modulus) }
        }
        return result
    }

    /// 小写 hex，左侧补零到指定字节数
    func hex(paddedTo byteCount: Int) -> String {
        var s = ""
        for limb in w.reversed() {
            s += String(format: "%08x", limb)
        }
        if s.count < byteCount * 2 {
            s = String(repeating: "0", count: byteCount * 2 - s.count) + s
        }
        return String(s.suffix(byteCount * 2))
    }
}
