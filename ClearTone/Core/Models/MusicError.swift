import Foundation

public enum MusicError: LocalizedError, Sendable, Equatable {
    case notLoggedIn
    /// 会话确实失效。**现在已经没有任何请求路径抛它** ——
    /// 判定会话失效需要 `/user/account` 旁证，结果通过
    /// `Notification.Name.clearToneSessionExpired` 广播，而不是以错误形式抛出。
    /// 保留这个 case 是因为它是那条广播对应的公开语义。
    case sessionExpired
    case networkUnavailable
    case rateLimited
    case songUnavailable(reason: String)
    case noPlayableURL
    case apiError(code: Int, message: String)
    case helperProcessUnavailable
    case helperProcessTimeout
    case helperAuthFailed
    /// 网络请求超时。**与 `.helperProcessTimeout` 的区别在于平台**：
    /// macOS 有本地 Node 辅助进程，超时确实是「本地服务没回」；
    /// iOS 是原生直连，压根没有辅助进程 —— 在那儿弹「本地服务响应超时」
    /// 只会让排查的人一头雾水。
    case requestTimeout
    case invalidResponse
    case cancelled
    case unsupportedFormat(String)
    case fileNotFound
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "尚未登录，请先登录网易云账号"
        case .sessionExpired: return "登录状态已过期，请重新登录"
        case .networkUnavailable: return "网络不可用，请检查网络连接"
        case .rateLimited: return "请求过于频繁，请稍后再试"
        case .songUnavailable(let reason): return "歌曲不可用：\(reason)"
        case .noPlayableURL: return "无法获取播放地址，可能没有播放权限"
        case .apiError(let code, let message): return "接口错误 (\(code))：\(message)"
        case .helperProcessUnavailable: return "本地服务不可用，请尝试重启应用"
        case .helperProcessTimeout: return "本地服务响应超时"
        case .helperAuthFailed: return "本地服务鉴权失败"
        case .requestTimeout: return "请求超时，请稍后重试"
        case .invalidResponse: return "服务器返回数据格式异常"
        case .cancelled: return "操作已取消"
        case .unsupportedFormat(let format): return "不支持的音频格式：\(format)"
        case .fileNotFound: return "文件不存在"
        case .unknown(let msg): return msg
        }
    }

    /// 给界面看的最终文案。**所有出口都在这里过一遍脱敏。**
    ///
    /// 服务端 `message` 与 `localizedDescription` 都是不受控文本：
    /// 前者可能把请求里的凭据原样回显（网易云的 cookie 注入出错时就会），
    /// 后者在英文系统上是英文。两者直接进 UI 等于把内部细节抛给用户。
    public var userFacingMessage: String {
        CTLog.sanitize(errorDescription ?? "未知错误")
    }

    /// 值得自动重试的错误。用于「加载失败 → 点重试」之外的自动退避重试。
    public var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .rateLimited, .helperProcessTimeout, .helperProcessUnavailable, .requestTimeout:
            return true
        case .apiError(let code, _):
            // 5xx 与 429 是服务端/限流侧的暂时问题；4xx 是请求本身错了，重试没用
            return code == 429 || (500...599).contains(code)
        default:
            return false
        }
    }

    /// 把任意 `Error` 归一化成 `MusicError`。
    ///
    /// 之前各处直接 `MusicError.unknown(error.localizedDescription)`，
    /// 有两个问题：
    /// 1. `localizedDescription` **随系统语言变化** —— 英文系统上用户看到
    ///    "The Internet connection appears to be offline."，而 App 其它地方
    ///    都是中文文案；单测也没法断言。
    /// 2. 底层 `URLError` 的语义（超时 / 断网 / 被取消）被整个丢掉，
    ///    `.cancelled` 认不出来，取消的请求会被当成真实失败弹给用户。
    /// 平台是否有本地 Node 辅助进程。
    ///
    /// iOS 走 `NeteaseDirectTransport` 原生直连，**没有** helper ——
    /// 「本地服务不可用/超时」这类文案在 iOS 上描述的是一个不存在的东西。
    static var isHelperBacked: Bool {
        #if os(iOS)
        return false
        #else
        return true
        #endif
    }

    /// `URLError.code` → `MusicError`。
    ///
    /// 抽成带 `helperBacked` 参数的纯函数，是为了让 macOS 上的离线单测
    /// 也能覆盖 iOS 那一半分支（测试 target 只跑 macOS）。
    static func normalizeURLError(_ code: URLError.Code, helperBacked: Bool) -> MusicError? {
        switch code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .networkUnavailable
        case .timedOut:
            return helperBacked ? .helperProcessTimeout : .requestTimeout
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .networkUnavailable
        case .resourceUnavailable:
            return helperBacked ? .helperProcessUnavailable : .networkUnavailable
        default:
            return nil
        }
    }

    public static func from(_ error: Error) -> MusicError {
        if let musicError = error as? MusicError { return musicError }

        if let urlError = error as? URLError,
           let mapped = normalizeURLError(urlError.code, helperBacked: isHelperBacked) {
            return mapped
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return .cancelled
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
            return .fileNotFound
        }

        // 刻意不用 localizedDescription：它随系统语言变化。
        // 附上 domain+code，排查时仍能定位，又不会泄露路径等细节。
        return .unknown("\(nsError.domain) \(nsError.code)")
    }
}

public extension Notification.Name {
    /// 网易云会话失效（cookie 过期/被踢）：用于全局清理登录态并弹出重新登录
    static let clearToneSessionExpired = Notification.Name("ClearToneSessionExpired")
}

public extension Error {
    /// 给界面看的错误文案。
    ///
    /// **所有写进 UI 的错误文案都必须走这里**，不要直接用
    /// `error.localizedDescription`：
    /// - `MusicError` 走自己的中文描述（不随系统语言变化）并脱敏；
    /// - 其它错误退回 `localizedDescription`，但至少脱敏一次 ——
    ///   服务端 message 与系统错误描述都是不受控文本，可能回显凭据。
    var ctUserMessage: String {
        if let musicError = self as? MusicError { return musicError.userFacingMessage }
        return CTLog.sanitize((self as NSError).localizedDescription)
    }
}
