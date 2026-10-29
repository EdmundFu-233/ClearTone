import Foundation

/// 带凭据请求的重定向闸门。
///
/// `URLSession` 默认会跟随 301/302/307/308，并把请求头原样带到新地址。
/// 本项目的网易云请求把 `Cookie`（登录凭据）和 `X-CT-Token`（本地辅助进程
/// 鉴权）放在 header 里，因此一次跨源跳转就足以把凭据交给另一个 host。
/// 上游或本机占用随机端口的进程只要返回一次重定向就能触发。
///
/// 这里在 `URLSessionTaskDelegate` 层拒绝白名单之外的跳转：
/// - 网易云请求只允许留在 `music.163.com` 及其子域，且不允许降级到 http；
/// - 本地辅助进程的请求不允许任何跳转（把空列表传进来即可）。
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHostSuffixes: [String]
    private let requiresHTTPS: Bool

    init(allowedHostSuffixes: [String] = [], requiresHTTPS: Bool = true) {
        self.allowedHostSuffixes = allowedHostSuffixes.map { $0.lowercased() }
        self.requiresHTTPS = requiresHTTPS
    }

    nonisolated static func isAllowed(
        _ request: URLRequest,
        allowedHostSuffixes: [String],
        requiresHTTPS: Bool
    ) -> Bool {
        guard let url = request.url, let host = url.host?.lowercased() else { return false }
        if requiresHTTPS, url.scheme?.lowercased() != "https" { return false }
        return allowedHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let allowed = Self.isAllowed(
            request,
            allowedHostSuffixes: allowedHostSuffixes,
            requiresHTTPS: requiresHTTPS
        )
        completionHandler(allowed ? request : nil)
    }
}
