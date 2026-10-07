import Foundation
import Combine

/// 排行榜目录的数据来源。
///
/// 抽成协议是为了让「加载 / 失败保留旧数据 / 旧响应丢弃」这些状态机行为
/// 能**离线**断言 —— 直接依赖 `NeteaseProvider.shared` 的话，
/// 任何断言都会变成对网络状况的猜测。
protocol TopListSource: Sendable {
    func fetchTopLists() async throws -> [TopList]
}

extension NeteaseProvider: TopListSource {}

/// 排行榜目录（`/toplist`）。
///
/// 放 `Core/` 而不是 `Features/`：它是一个带代次令牌与错误态的状态机，
/// 而 `project.yml` 把 `Features/**` 排除在测试 target 之外 ——
/// 放在那里一条断言都写不了（macOS 的 `TopListStore` 就是这么废掉的）。
///
/// 榜单本身就是一个歌单，点进去直接喂 `playlist/detail`，所以这里只需要目录。
@MainActor
final class TopListSession: ObservableObject {

    @Published private(set) var lists: [TopList] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let source: TopListSource
    private var token = UUID()

    init(source: TopListSource = NeteaseProvider.shared) {
        self.source = source
    }

    /// 加载榜单目录。
    ///
    /// 失败**保留旧数据**、只置 `errorMessage`：整屏闪空比旧数据更糟，
    /// 而且重试按钮要靠这个错误态才显示得出来。
    func load() async {
        let token = UUID()
        self.token = token
        // 已有内容时不显示整屏 loading：刷新走 `refreshable`，闪一下空白很难看
        isLoading = lists.isEmpty
        errorMessage = nil
        // 必须用 defer 收尾：`.task` 会在视图消失时取消，若靠末尾的赋值来复位，
        // 取消路径会让 `isLoading` 永久停在 true（面板一直转圈、空态与重试按钮都不显示）。
        defer { if self.token == token { isLoading = false } }
        do {
            let loaded = try await source.fetchTopLists()
            guard self.token == token, !Task.isCancelled else { return }
            lists = loaded
        } catch {
            guard self.token == token, !Task.isCancelled else { return }
            errorMessage = error.ctUserMessage
            CTLog.general.error("加载榜单目录失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }
}
