import Foundation
import Combine

protocol MobileLoginProvider: MusicProvider {
    func fetchAccountInfo(cookie: String) async throws -> AccountInfo?
}
extension NeteaseProvider: MobileLoginProvider {}

@MainActor
final class MobileLoginSession: ObservableObject {
    @Published private(set) var key: String?
    @Published private(set) var status = "正在生成二维码…"
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var account: AccountInfo?
    private let provider: any MobileLoginProvider
    private let saveCredentials: (String, String) throws -> Void
    private var generation = 0

    init(provider: any MobileLoginProvider = NeteaseProvider.shared,
         saveCredentials: @escaping (String, String) throws -> Void = { cookie, userID in
             try KeychainStore.shared.save(cookie, for: .neteaseCookie)
             try KeychainStore.shared.save(userID, for: .neteaseUserID)
         }) {
        self.provider = provider
        self.saveCredentials = saveCredentials
    }

    func poll() async {
        generation += 1
        let token = generation
        key = nil; account = nil; errorMessage = nil; isLoading = true
        defer { if token == generation { isLoading = false } }
        do {
            let generated = try await provider.fetchQRCodeKey()
            guard token == generation, !Task.isCancelled else { return }
            key = generated; status = "请使用网易云音乐扫描二维码"
            for _ in 0..<120 {
                try Task.checkCancellation()
                let response = try await provider.checkQRCodeStatus(key: generated)
                guard token == generation, !Task.isCancelled else { return }
                switch response {
                case .waitingScan: status = "等待扫码；也可以将二维码保存后从相册识别"
                case .scannedWaitingConfirm: status = "已扫码，请在网易云音乐中确认"
                case .success(let cookie):
                    try await commit(cookie: cookie, token: token)
                    return
                case .expired:
                    key = nil; status = "二维码已过期，请刷新"
                    return
                case .failed(let message): throw MusicError.unknown(message)
                }
                try await Task.sleep(for: .seconds(2))
            }
            key = nil; status = "二维码已过期，请刷新"
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            errorMessage = error.ctUserMessage
            CTLog.general.error("二维码登录轮询失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }

    func login(cookie: String) async {
        generation += 1
        let token = generation
        key = nil; account = nil; errorMessage = nil; isLoading = true
        defer { if token == generation { isLoading = false } }
        do { try await commit(cookie: cookie, token: token) }
        catch {
            guard token == generation, !Task.isCancelled else { return }
            errorMessage = error.ctUserMessage
            // 登录失败是排查成本最高的一类：界面只给一句通用提示，
            // 不留日志的话，「cookie 归一化后为空」和「账号接口拒绝」完全无法区分。
            CTLog.general.error("Cookie 登录失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }

    private func commit(cookie: String, token: Int) async throws {
        let normalized = NeteaseCookieNormalizer.normalize(cookie)
        guard !normalized.isEmpty else { throw MusicError.notLoggedIn }
        guard let info = try await provider.fetchAccountInfo(cookie: normalized) else { throw MusicError.notLoggedIn }
        guard token == generation, !Task.isCancelled else { return }
        try saveCredentials(normalized, info.userID)
        account = info
        status = "登录成功"
    }

    func cancel() {
        generation += 1
        isLoading = false
        key = nil
    }
}
