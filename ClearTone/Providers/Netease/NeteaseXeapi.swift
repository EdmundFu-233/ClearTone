import Foundation
import CryptoKit
import CommonCrypto
import Security
import zlib

/// 对齐打包上游 util/crypto.js 的 xeapi；不依赖 Node、JIT 或远程代理。
/// X25519 + HMAC 派生密钥 + AES-GCM 封装，AES-ECB 双层请求与响应解密。
actor NeteaseXeapi {
    static let shared = NeteaseXeapi()
    struct PublicKey: Codable, Sendable {
        let publicKey: String
        let version: String
        let sk: String
    }
    private var key: PublicKey?
    private var keyTask: Task<PublicKey, Error>?
    /// 设备标识。**必须跨启动稳定** —— 每次启动换一个，等于告诉风控
    /// 「同一台设备每次来都换了身份」。key 注册请求、`x-deviceid` 头、
    /// Cookie 里的 `deviceId` 用的都是它。
    let deviceID: String
    private static let deviceIDKey = "NeteaseXeapi.deviceID"
    private let session: URLSession
    private static let userAgent = "NeteaseMusic/9.5.61.260802021928(9005061);Dalvik/2.1.0 (Linux; U; Android 12; HBN-AL00 Build/cd737a2.0)"
    static let staticKey = Data([0xab,0x1d,0x5a,0x43,0x0f,0x6b,0xb0,0x4a,0x3f,0x01,0xe8,0x1d,0xdd,0x72,0xbd,0x91,0x6d,0x5c,0xe5,0x91,0x24,0x8a,0xc1,0x28,0x71,0x48,0x06,0xd7,0xf8,0xfb,0x1b,0x84])
    init() {
        let stored = UserDefaults.standard.string(forKey: Self.deviceIDKey)
        let resolved = Self.resolveDeviceID(stored)
        if stored != resolved { UserDefaults.standard.set(resolved, forKey: Self.deviceIDKey) }
        deviceID = resolved
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }

    /// 已存的标识合法就原样复用，否则生成一个 32 位十六进制。
    ///
    /// 抽成纯函数是为了能离线断言「合法的不被换掉」——
    /// `init` 里直接写 `UUID()` 的话，每次启动都换 id 而没人会发现。
    static func resolveDeviceID(_ existing: String?) -> String {
        if let existing, existing.count == 32, existing.allSatisfy(\.isHexDigit) { return existing }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    static func sign(timestamp: String, nonce: String) -> String {
        let key = SymmetricKey(data: Data("mUHCwVNWJbunMqAHf5MImuirT6plvs6VSFW62MGHstFQxhBGdEoIhLItH3djc4+FB/OKty3+lL2rGeoFBpVe5g==".utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: Data((timestamp + nonce).utf8), using: key)).base64EncodedString()
    }

    static func aes(_ data: Data, key: Data, decrypt: Bool = false) throws -> Data {
        guard [16, 24, 32].contains(key.count) else { throw MusicError.invalidResponse }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var count = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count,
                            nil, input.baseAddress, data.count, out.baseAddress, capacity, &count)
                }
            }
        }
        guard status == kCCSuccess else { throw MusicError.invalidResponse }
        output.count = count
        return output
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw MusicError.invalidResponse }
        return data
    }

    /// 可注入随机源用于与 Node 标准向量逐字节对照。
    static func encrypt(payload: OrderedJSON.Value, key: PublicKey, dynamicKey: Data,
                        mask: Data, privateKey: Curve25519.KeyAgreement.PrivateKey, nonce: AES.GCM.Nonce) throws -> [String: String] {
        guard mask.count == 16, dynamicKey.count == 16,
              let rawPeer = Data(base64Encoded: key.publicKey), rawPeer.count == 32 else { throw MusicError.invalidResponse }
        let body = payload.objectPairs.map { pair in
            let value: String
            if case .string(let raw) = pair.1 { value = raw } else { value = OrderedJSON.encode(pair.1) }
            return NeteaseCrypto.formEncode(pair.0) + "=" + NeteaseCrypto.formEncode(value)
        }.joined(separator: "&")
        let plain = OrderedJSON.encode(.object([("body", .string(Data(body.utf8).base64EncodedString())), ("queryString", .string("e_r=true"))]))
        let inner = try aes(Data(plain.utf8), key: staticKey)
        let xored = Data(inner.enumerated().map { $0.element ^ mask[$0.offset & 15] })
        let b64 = Data(xored.base64EncodedString().utf8)
        let rotation = Int(mask[0] & 15) % b64.count
        let middle = mask + b64.dropFirst(rotation) + b64.prefix(rotation)
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawPeer)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        let prk = Data(HMAC<SHA256>.authenticationCode(for: sharedBytes, using: SymmetricKey(data: Data(repeating: 0, count: 32))))
        let ephemeral = privateKey.publicKey.rawRepresentation
        let derived = Data(HMAC<SHA256>.authenticationCode(for: ephemeral + Data([1]), using: SymmetricKey(data: prk))).prefix(16)
        let sealed = try AES.GCM.seal(Data("\(dynamicKey.base64EncodedString())|android|\(key.sk)".utf8), using: SymmetricKey(data: derived), nonce: nonce)
        let nonceData = nonce.withUnsafeBytes { Data($0) }
        return [
            "B": try aes(middle, key: dynamicKey).base64EncodedString(),
            "S": (ephemeral + nonceData + sealed.ciphertext + sealed.tag).base64EncodedString(),
            "R": try aes(Data("\(key.version)|".utf8), key: staticKey).base64EncodedString(),
        ]
    }

    private func fetchKey() async throws -> PublicKey {
        if let key { return key }
        if let keyTask { return try await keyTask.value }
        let task = Task { try await self.registerKey() }
        keyTask = task
        defer { keyTask = nil }
        let fetched = try await task.value
        key = fetched
        return fetched
    }

    private func registerKey() async throws -> PublicKey {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = (0..<16).map { _ in String(Int.random(in: 0...9)) }.joined()
        let params = ["appVersion": "9.5.61", "currentKeyVersion": "", "deviceId": deviceID, "nonce": nonce,
                      "os": "android", "requestType": "active", "signature": Self.sign(timestamp: timestamp, nonce: nonce),
                      "t1": "", "t2": "", "timestamp": timestamp, "uid": ""]
        var request = URLRequest(url: URL(string: "https://interface.music.163.com/api/gorilla/anti/crawler/security/key/get")!)
        request.httpMethod = "POST"
        request.httpBody = Self.form(params)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("deviceId=\(deviceID)", forHTTPHeaderField: "Cookie")
        let data = try await perform(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["code"] as? Int == 200, let body = json["data"] as? [String: Any],
              let encrypted = body["encryptedData"] as? String, let cipher = Data(base64Encoded: encrypted),
              let responseTimestamp = body["timestamp"], let signature = body["signature"] as? String,
              Self.sign(timestamp: String(describing: responseTimestamp), nonce: nonce) == signature else { throw MusicError.invalidResponse }
        let keyData = try Self.aes(cipher, key: Self.staticKey, decrypt: true)
        let fetched = try JSONDecoder().decode(PublicKey.self, from: keyData)
        guard !fetched.sk.isEmpty, Data(base64Encoded: fetched.publicKey)?.count == 32 else { throw MusicError.invalidResponse }
        return fetched
    }

    /// Set-Cookie 的属性不是 cookie，混进请求头只会让对端困惑
    private static let setCookieAttributes: Set<String> = [
        "path", "domain", "expires", "max-age", "httponly", "secure",
        "samesite", "version", "comment",
    ]

    /// 把调用方的 cookie 与 xeapi 冒充 Android 客户端所必需的固定字段合并成一条 Cookie 头。
    ///
    /// 早先是 `cookie + "; os=android; ..."` 直接拼接 —— 登录接口回的那份里
    /// 本来就可能带 `os=` / `deviceId=`，同一个名称出现两次，
    /// 服务端取前一个还是后一个完全看运气（也就是说**可能拿到 iOS 身份的响应**）。
    ///
    /// 这里先归一化成字典（按名大小写不敏感地覆盖），固定字段一律以本层为准。
    static func mergeCookie(_ cookie: String?, deviceID: String, buildver: String) -> String {
        var jar: [(String, String)] = []
        // 名称按大小写不敏感去重，且**以本次写入的名字为准** ——
        // 否则 `DeviceId=old` 会被后来的 `deviceId=` 又加一遍。
        func set(_ name: String, _ value: String) {
            jar.removeAll { $0.0.caseInsensitiveCompare(name) == .orderedSame }
            jar.append((name, value))
        }
        for part in (cookie ?? "").split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }   // HttpOnly / Secure 这类无值属性
            guard !setCookieAttributes.contains(kv[0].lowercased()) else { continue }
            set(kv[0], kv[1])
        }
        set("os", "android")
        set("appver", "9.1.65")
        set("osver", "16")
        set("deviceId", deviceID)
        set("sDeviceId", deviceID)
        set("buildver", buildver)
        return jar.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    func request(path: String, payload: OrderedJSON.Value, cookie: String?) async throws -> Data {
        let publicKey = try await fetchKey()
        let fields = try Self.encrypt(payload: payload, key: publicKey, dynamicKey: Self.randomBytes(16),
                                      mask: Self.randomBytes(16), privateKey: Curve25519.KeyAgreement.PrivateKey(), nonce: AES.GCM.Nonce())
        var request = URLRequest(url: URL(string: "https://interface3.music.163.com/xeapi/" + path.dropFirst(5))!)
        request.httpMethod = "POST"
        request.httpBody = Self.form(fields)
        let build = String(Int(Date().timeIntervalSince1970))
        let headers = ["Content-Type": "application/x-www-form-urlencoded;charset=utf-8", "User-Agent": Self.userAgent,
                       "X-Client-Enc-State": "ENCRYPTED", "x-aeapi": "true", "x-deviceid": deviceID,
                       "x-sdeviceid": deviceID, "x-os": "android", "x-osver": "16", "x-appver": "9.1.65", "x-buildver": build]
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(Self.mergeCookie(cookie, deviceID: deviceID, buildver: build), forHTTPHeaderField: "Cookie")
        for part in (cookie ?? "").split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == "MUSIC_U" { request.setValue(kv[1], forHTTPHeaderField: "x-music-u") }
        }
        let raw = try await perform(request)
        if (try? JSONSerialization.jsonObject(with: raw)) != nil { return raw }
        let decrypted = try Self.aes(raw, key: Data("e82ckenh8dichen8".utf8), decrypt: true)
        return try Self.inflateIfNeeded(decrypted)
    }

    static func form(_ params: [String: String]) -> Data {
        Data(params.sorted { $0.key < $1.key }.map { NeteaseCrypto.formEncode($0.key) + "=" + NeteaseCrypto.formEncode($0.value) }.joined(separator: "&").utf8)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MusicError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw MusicError.apiError(code: http.statusCode, message: "网易云请求失败（\(http.statusCode)）") }
        return data
    }

    static func inflateIfNeeded(_ data: Data) throws -> Data {
        guard data.starts(with: [0x1f, 0x8b]) else { return data }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw MusicError.invalidResponse }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(data.count)
            var output = Data()
            var status: Int32 = Z_OK
            repeat {
                var buffer = [UInt8](repeating: 0, count: 16384)
                let produced = buffer.withUnsafeMutableBufferPointer { bytes -> Int in
                    stream.next_out = bytes.baseAddress!
                    stream.avail_out = uInt(bytes.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return bytes.count - Int(stream.avail_out)
                }
                guard status == Z_OK || status == Z_STREAM_END, output.count + produced <= 8 * 1024 * 1024,
                      produced > 0 || status == Z_STREAM_END else { throw MusicError.invalidResponse }
                output.append(contentsOf: buffer.prefix(produced))
            } while status != Z_STREAM_END
            return output
        }
    }
}
