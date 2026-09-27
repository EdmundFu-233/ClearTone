import Foundation
import Combine

/// 搜索辅助：联想词、热搜词、本地搜索历史。
///
/// 放在 `Core/Search/` 而不是 `Features/Search/`，理由与 `SearchSession` 相同：
/// 它是**状态机**而非视图，测试 target 排除了整个 `Features/`，
/// 放这里才能被单元测试覆盖。
///
/// 联想请求**节流** 250ms 且丢弃过期响应 —— 输入中文时 IME 会连续触发
/// 多次变更，逐次请求既浪费又会让结果乱序。
/// 联想/热搜的数据来源。
///
/// 抽成协议是为了让节流与历史逻辑能**离线**测试：直接依赖
/// `NeteaseProvider.shared` 的话，任何关于「有没有发请求」的断言都得联网，
/// 断言就变成了对网络状况的猜测。
protocol SearchAssistSource: Sendable {
    func fetchSearchSuggestions(keyword: String) async throws -> [SearchSuggestion]
    func fetchHotSearchTerms() async throws -> [HotSearchTerm]
}

extension NeteaseProvider: SearchAssistSource {}

@MainActor
final class SearchAssistStore: ObservableObject {

    @Published private(set) var suggestions: [SearchSuggestion] = []
    @Published private(set) var isLoadingSuggestions = false
    @Published private(set) var hotTerms: [HotSearchTerm] = []
    @Published private(set) var isLoadingHot = false
    @Published private(set) var hotError: String?
    @Published private(set) var history: [String] = []

    private let source: SearchAssistSource
    private var suggestionToken = UUID()
    private var debounceTask: Task<Void, Never>?
    /// 联想节流间隔。250ms 约等于一次中文输入的停顿。
    private static let debounceInterval: Duration = .milliseconds(250)
    /// 历史最多保留的条数
    private static let historyLimit = 20

    private static let historyKey = "cleartone.search.history"

    /// 存根可注入。生产用 `.standard`；测试用独立 suite，避免污染真实用户数据
    /// （`UserDefaults.standard` 在 Swift 6 下是只读的，测试无法替换）。
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, source: SearchAssistSource = NeteaseProvider.shared) {
        self.defaults = defaults
        self.source = source
        history = defaults.stringArray(forKey: Self.historyKey) ?? []
    }

    // MARK: - 联想

    /// 输入变化时调用。内部节流 + 代次隔离。
    func querySuggestions(_ keyword: String) {
        debounceTask?.cancel()
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            isLoadingSuggestions = false
            return
        }
        let token = UUID()
        suggestionToken = token
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            await self?.fetchSuggestions(trimmed, token: token)
        }
    }

    private func fetchSuggestions(_ keyword: String, token: UUID) async {
        isLoadingSuggestions = true
        defer {
            if suggestionToken == token { isLoadingSuggestions = false }
        }
        do {
            let loaded = try await source.fetchSearchSuggestions(keyword: keyword)
            guard suggestionToken == token, !Task.isCancelled else { return }
            suggestions = loaded
        } catch {
            // 联想失败不打扰用户：静默清空即可
            guard suggestionToken == token else { return }
            suggestions = []
        }
    }

    func clearSuggestions() {
        debounceTask?.cancel()
        suggestions = []
        isLoadingSuggestions = false
    }

    // MARK: - 热搜

    func loadHotTerms() async {
        guard hotTerms.isEmpty, !isLoadingHot else { return }
        isLoadingHot = true
        hotError = nil
        do {
            let loaded = try await source.fetchHotSearchTerms()
            guard !Task.isCancelled else { return }
            hotTerms = loaded
        } catch {
            guard !Task.isCancelled else { return }
            hotError = error.ctUserMessage
        }
        guard !Task.isCancelled else { return }
        isLoadingHot = false
    }

    // MARK: - 搜索历史

    /// 提交一次搜索后记录。空关键词与纯空白不入历史。
    func recordSearch(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        history.insert(trimmed, at: 0)
        if history.count > Self.historyLimit {
            history = Array(history.prefix(Self.historyLimit))
        }
        defaults.set(history, forKey: Self.historyKey)
    }

    func removeHistory(_ keyword: String) {
        history.removeAll { $0 == keyword }
        defaults.set(history, forKey: Self.historyKey)
    }

    func clearHistory() {
        history = []
        defaults.set([], forKey: Self.historyKey)
    }
}
