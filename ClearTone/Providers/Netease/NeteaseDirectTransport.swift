import Foundation

/// iOS 直连网易云：不经本地辅助进程。
///
/// ## 为什么需要它
///
/// macOS 版通过 Node.js 辅助进程（api-enhanced）访问网易云，封装在
/// `HelperProcessManager` 里。iOS 上这条路径不可用：
/// - **没有 `Process()`**，无法拉起子进程
/// - 打包的 `node` 是 macOS Mach-O 二进制（104MB），iOS 无法运行
///
/// 所以 iOS 必须自己构造请求。加密由 `NeteaseCrypto` 完成（已逐字节对过
/// Node 标准答案）。
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

    private func perform(url: String, body: Data, cookie: String?) async throws -> Data {
        guard let target = URL(string: url) else { throw MusicError.invalidResponse }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie + clientCookieSuffix, forHTTPHeaderField: "Cookie")
        }
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MusicError.invalidResponse }
            if http.statusCode == 301 || http.statusCode == 401 || http.statusCode == 403 {
                throw MusicError.apiError(code: 301, message: "登录状态已失效")
            }
            if http.statusCode == 429 { throw MusicError.rateLimited }
            guard (200...299).contains(http.statusCode) else {
                throw MusicError.apiError(code: http.statusCode, message: "HTTP \(http.statusCode)")
            }
            // HTTP 200 但空 body 是表单编码错误（base64 的 + 未编码）的特征
            if data.isEmpty {
                throw MusicError.invalidResponse
            }
            return data
        } catch let error as URLError where error.code == .cancelled {
            throw MusicError.cancelled
        } catch let error as URLError
            where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw MusicError.networkUnavailable
        } catch {
            if let musicError = error as? MusicError { throw musicError }
            throw MusicError.unknown(error.localizedDescription)
        }
    }
}
