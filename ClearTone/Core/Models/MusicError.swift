import Foundation

public enum MusicError: LocalizedError, Sendable {
    case notLoggedIn
    case sessionExpired
    case networkUnavailable
    case rateLimited
    case songUnavailable(reason: String)
    case noPlayableURL
    case apiError(code: Int, message: String)
    case helperProcessUnavailable
    case helperProcessTimeout
    case helperAuthFailed
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
        case .invalidResponse: return "服务器返回数据格式异常"
        case .cancelled: return "操作已取消"
        case .unsupportedFormat(let format): return "不支持的音频格式：\(format)"
        case .fileNotFound: return "文件不存在"
        case .unknown(let msg): return msg
        }
    }
}

public extension Notification.Name {
    /// 网易云会话失效（cookie 过期/被踢）：用于全局清理登录态并弹出重新登录
    static let clearToneSessionExpired = Notification.Name("ClearToneSessionExpired")
}
