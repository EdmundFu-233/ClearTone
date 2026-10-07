import Foundation
import Combine

/// 账号页数据：听歌等级 / 打卡 / 听歌排行。
@MainActor
final class ProfileStore: ObservableObject {

    @Published private(set) var level: UserLevelInfo?
    @Published private(set) var isLoadingLevel = false
    @Published private(set) var levelError: String?

    @Published private(set) var signInResult: SignInResult?
    @Published private(set) var isSigningIn = false

    @Published private(set) var records: [ListenRecord] = []
    @Published private(set) var isLoadingRecords = false
    @Published private(set) var recordsError: String?
    /// 听歌排行的时间范围
    @Published var recordsWeekly = false {
        didSet { if recordsWeekly != oldValue { Task { await loadRecords() } } }
    }

    private let provider = NeteaseProvider.shared
    /// 等级与听歌记录是**两个独立资源**，必须各自一个令牌。
    /// 原来共用一个：两者都被 `ProfileView` 用 `async let` 同时启动，
    /// 后启动的 `loadRecords` 会覆盖 `loadLevel` 的令牌，于是
    /// `guard token == current` 失败 → `isLoadingLevel = false` 那一行不可达
    /// → 等级卡片永久转圈，且没有任何错误与重试入口。
    private var levelToken = UUID()
    private var recordsToken = UUID()

    // MARK: - 等级

    func loadLevel() async {
        let current = UUID()
        levelToken = current
        isLoadingLevel = level == nil
        levelError = nil
        // defer 兜底：取消 / 换令牌时提前 return，不能让 loading 永久卡住
        defer { if levelToken == current { isLoadingLevel = false } }
        do {
            let loaded = try await provider.fetchUserLevel()
            guard levelToken == current, !Task.isCancelled else { return }
            level = loaded
        } catch {
            guard levelToken == current else { return }
            levelError = error.ctUserMessage
        }
    }

    // MARK: - 打卡

    func signIn() async {
        // 失败后允许重试：否则按钮可点，但 guard 直接返回、看起来毫无反应
        if case .failed = signInResult { resetSignIn() }
        guard signInResult == nil, !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            signInResult = try await provider.dailySignIn()
            // 打卡会改变连续登录天数，刷新等级
            if signInResult?.isSuccess == true { await loadLevel() }
        } catch {
            signInResult = .failed(error.ctUserMessage)
        }
    }

    /// 允许重试（失败后或「已打卡」状态下都不该锁死按钮）
    func resetSignIn() { signInResult = nil }

    // MARK: - 听歌排行

    func loadRecords() async {
        let current = UUID()
        recordsToken = current
        isLoadingRecords = records.isEmpty
        recordsError = nil
        defer { if recordsToken == current { isLoadingRecords = false } }
        do {
            let loaded = try await provider.fetchListenRecords(weekly: recordsWeekly)
            guard recordsToken == current, !Task.isCancelled else { return }
            records = loaded
        } catch {
            guard recordsToken == current else { return }
            recordsError = error.ctUserMessage
        }
    }
}
