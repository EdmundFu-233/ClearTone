import Foundation

/// 不经辅助进程、直接向网易云发请求的传输层。
///
/// iOS 的生产传输；macOS 继续走辅助进程。
/// 路由参数转换见 NeteaseMobileRoute，xeapi 见 NeteaseXeapi。
/// 响应解析仍与 macOS 共用 NeteaseProvider。
///
/// ## 两种请求形态（实测确认）
///
/// 网易云接口分两类，都用 POST + `application/x-www-form-urlencoded`：
///
/// 1. **明文 api** —— 直接 POST 表单到 `interface.music.163.com` + 原始 uri。
///    实测可用：playlist/detail、song/url/v1、lyric、cloudsearch、song/like/get
///    等 8 个接口全部 code 200。
/// 2. **weapi** —— AES + RSA 加密参数，POST 到 `music.163.com/weapi/` + uri 去掉
///    前 5 字符（`/api/` → 剩余部分）。实测 12 个接口 code 200。
///
/// ## 三个必须遵守的细节
///
/// 1. **必须补客户端标识 cookie**（`os` / `appver` / `osver` / `versioncode` 等）。
///    缺失时写接口返回 `-460 检测到您的网络环境存在风险`。
///    注意：macOS 版曾把 -460/524 误判为「GET 方法不对」，实际是缺这些字段。
/// 2. **表单编码要对标 `URLSearchParams`**，base64 的 `+` 必须编成 `%2B`。
///    否则 **HTTP 200 但 body 为空**。
/// 3. **写操作必须 POST**。GET 时网易云返回 524 / 405。
public actor NeteaseDirectTransport {

    public static let shared = NeteaseDirectTransport()

    private let session: URLSession

    /// 客户端标识。缺失会导致写接口被风控（-460）。
    private let clientCookieSuffix = "; __remember_me=true; ntes_kaola_ad=1; WEVNSM=1.0.0"
        + "; os=pc; appver=2.9.7; osver=linux; versioncode=140"
        + "; channel=netease; resolution=1920x1080; buildver=20240101.000000"

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        + " (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        // 凭据一律手动放进 Cookie 头，不依赖 cookie 存储
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - 请求

    /// 明文 api 请求：POST 表单到 interface 域
    public func plainAPI(
        _ apiPath: String,
        params: [String: String],
        cookie: String?
    ) async throws -> Data {
        var form = params.map { key, value in
            "\(NeteaseCrypto.formEncode(key))=\(NeteaseCrypto.formEncode(value))"
        }
        form.sort()
        let body = form.joined(separator: "&").data(using: .utf8) ?? Data()
        let url = "https://interface.music.163.com" + apiPath
        return try await perform(url: url, body: body, cookie: cookie)
    }

    /// weapi 请求：AES+RSA 加密后 POST 到 music 域
    public func weapi(
        _ apiPath: String,
        params: [String: Any],
        cookie: String?
    ) async throws -> Data {
        var payload = params
        let csrf = cookie.map { NeteaseCrypto.csrfToken(fromCookie: $0) } ?? ""
        payload["csrf_token"] = csrf

        let encrypted = try NeteaseCrypto.weapi(payload)
        let form = "params=\(NeteaseCrypto.formEncode(encrypted.params))"
            + "&encSecKey=\(NeteaseCrypto.formEncode(encrypted.encSecKey))"
        // /api/radio/like → weapi/radio/like（去掉前 5 个字符 "/api/"）
        let trimmed = String(apiPath.dropFirst(5))
        let url = "https://music.163.com/weapi/" + trimmed
        return try await perform(
            url: url, body: Data(form.utf8), cookie: cookie
        )
    }

    /// eapi 请求：AES-128-ECB 加密后 POST 到 interfacepc 域。
    ///
    /// 与 weapi 的两点差异：
    /// 1. 目标域是 `interfacepc.music.163.com`（`APP_CONF.eapiDomain`），
    ///    路径是 `/eapi/` + uri 去掉前 5 字符。
    /// 2. 请求体只有一个 `params` 字段（大写 hex），且参数里必须带
    ///    `header` 对象 —— 它同时也是要发出去的 Cookie。
    ///
    /// ## 已知的脆弱点
    ///
    /// eapi 的签名覆盖整个 `JSON.stringify` 结果，**包括 `header` 的键序**。
    /// 上游模块一旦增删 `data` 的字段，iOS 这条路的签名就会失效
    /// （表现为 code 400 / 签名错误，macOS 走辅助进程不受影响）。
    /// 因此 `NeteaseEndpoint` 里只有**键序确定**的路由才标 `.eapi`。
    public func eapi(
        _ apiPath: String,
        payload: OrderedJSON.Value,
        cookie: String?
    ) async throws -> Data {
        let csrf = cookie.map { NeteaseCrypto.csrfToken(fromCookie: $0) } ?? ""
        let (musicU, musicA) = cookieValues(cookie)
        let header = NeteaseCrypto.eapiHeader(
            os: "osx",
            osver: "10.15.7",
            appver: "2.9.7",
            versioncode: "140",
            deviceId: "p6i5y8e9w2s4h7g3",
            resolution: "1920x1080",
            buildver: NeteaseCrypto.eapiBuildVersion(),
            channel: "netease",
            csrf: csrf,
            musicU: musicU,
            musicA: musicA
        )
        let params = try NeteaseCrypto.eapi(
            uri: apiPath,
            payload: .object(payload.objectPairs + [("e_r", .bool(false)), ("header", header)])
        )
        let form = "params=\(NeteaseCrypto.formEncode(params))"
        let trimmed = String(apiPath.dropFirst(5))
        let url = "https://interfacepc.music.163.com/eapi/" + trimmed
        return try await perform(
            url: url,
            body: Data(form.utf8),
            cookie: cookie,
            extraHeaderCookie: headerCookie(header)
        )
    }

    /// 从 cookie 串里取出 MUSIC_U / MUSIC_A
    private func cookieValues(_ cookie: String?) -> (String?, String?) {
        guard let cookie, !cookie.isEmpty else { return (nil, nil) }
        var musicU: String?
        var musicA: String?
        for part in cookie.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            switch kv[0].trimmingCharacters(in: .whitespaces) {
            case "MUSIC_U": musicU = String(kv[1])
            case "MUSIC_A": musicA = String(kv[1])
            default: break
            }
        }
        return (musicU, musicA)
    }

    /// 对标 Node 侧的 `createHeaderCookie`：把 header 序列化成 `k=v; k=v`
    private func headerCookie(_ header: OrderedJSON.Value) -> String {
        guard case .object(let pairs) = header else { return "" }
        return pairs
            .map { "\($0.0)=\(Self.headerValueString($0.1))" }
            .joined(separator: "; ")
    }

    private static func headerValueString(_ value: OrderedJSON.Value) -> String {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        case .double(let d): return String(d)
        default: return ""
        }
    }

    /// JSON 值 → 表单字符串。
    ///
    /// **不能用 `String(describing:)`**：`JSONSerialization` 给回来的是 `NSNumber`，
    /// 布尔会被描述成 `"1"`/`"0"`（Node 的 `querystring` 发的是 `"true"`/`"false"`），
    /// 数组会被描述成多行的 `(\n 1,\n 2\n)`。两种都会让对端收下错的 body，
    /// 而响应只是「参数不对」，不指向任何一行代码。
    ///
    /// 遇到标量以外的类型直接抛错 —— 宁可显式失败，也不猜。
    static func formValues(from payload: [String: Any]) throws -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in payload {
            switch value {
            case let string as String:
                out[key] = string
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    out[key] = number.boolValue ? "true" : "false"
                } else {
                    out[key] = number.stringValue
                }
            default:
                throw MusicError.invalidResponse
            }
        }
        return out
    }

    private func perform(
        url: String,
        body: Data,
        cookie: String?,
        extraHeaderCookie: String? = nil
    ) async throws -> Data {
        guard let target = URL(string: url) else { throw MusicError.invalidResponse }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(extraHeaderCookie ?? ((cookie ?? "") + clientCookieSuffix), forHTTPHeaderField: "Cookie")
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MusicError.invalidResponse }
            if http.statusCode == 301 || http.statusCode == 401 || http.statusCode == 403 {
                throw MusicError.apiError(code: http.statusCode, message: "网易云拒绝了这次请求，请稍后重试")
            }
            if http.statusCode == 429 { throw MusicError.rateLimited }
            guard (200...299).contains(http.statusCode) else {
                throw MusicError.apiError(code: http.statusCode, message: "HTTP \(http.statusCode)")
            }
            // HTTP 200 但空 body 是表单编码错误（base64 的 + 未编码）的特征
            if data.isEmpty {
                throw MusicError.invalidResponse
            }
            if target.path == "/eapi/login/qrcode/client/login",
               var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                    result[String(describing: pair.key)] = String(describing: pair.value)
                }, for: target)
                json["cookie"] = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                return try JSONSerialization.data(withJSONObject: json)
            }
            return data
        } catch let error as URLError where error.code == .cancelled {
            throw MusicError.cancelled
        } catch let error as URLError
            where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw MusicError.networkUnavailable
        } catch {
            if let musicError = error as? MusicError { throw musicError }
            throw MusicError.from(error)
        }
    }
}


extension NeteaseDirectTransport {
    func mobileRequest(_ route: String, query: [String: String], cookie: String?) async throws -> Data {
        // helper 的 track/all 是先读 trackIds 再查 song/detail 的复合接口。
        if route == "/playlist/track/all" {
            let detail = try await mobileRequest("/playlist/detail", query: ["id": query["id"] ?? ""], cookie: cookie)
            guard let json = try JSONSerialization.jsonObject(with: detail) as? [String: Any],
                  let playlist = json["playlist"] as? [String: Any],
                  let tracks = playlist["trackIds"] as? [[String: Any]],
                  let offset = Int(query["offset"] ?? "0"), offset >= 0,
                  let limit = Int(query["limit"] ?? "100"), (1...1000).contains(limit) else { throw MusicError.invalidResponse }
            let ids = tracks.dropFirst(offset).prefix(limit).compactMap { $0["id"].map { String(describing: $0) } }
            if ids.isEmpty { return Data("{\"songs\":[],\"code\":200}".utf8) }
            return try await mobileRequest("/song/detail", query: ["ids": ids.joined(separator: ",")], cookie: cookie)
        }
        let request = try NeteaseMobileRoute.make(route, query: query)
        let data: Data
        switch request.crypto {
        case .plain:
            let payload = try JSONSerialization.jsonObject(with: Data(OrderedJSON.encode(request.payload).utf8)) as? [String: Any] ?? [:]
            data = try await plainAPI(request.path, params: try Self.formValues(from: payload), cookie: cookie)
        case .weapi:
            let payload = try JSONSerialization.jsonObject(with: Data(OrderedJSON.encode(request.payload).utf8)) as? [String: Any] ?? [:]
            data = try await weapi(request.path, params: payload, cookie: cookie)
        case .eapi:
            data = try await eapi(request.path, payload: request.payload, cookie: cookie)
        case .xeapi:
            data = try await NeteaseXeapi.shared.request(path: request.path, payload: request.payload, cookie: cookie)
        }
        if route == "/login/qr/key" {
            let json = try JSONSerialization.jsonObject(with: data)
            return try JSONSerialization.data(withJSONObject: ["code": 200, "data": json])
        }
        return data
    }
}
