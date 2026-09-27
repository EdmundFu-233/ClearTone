import Foundation

/// 菜单命令拿不到 `@EnvironmentObject`，用一个弱引用桥接当前 AppState。
///
/// 用弱引用避免和 `@StateObject` 形成保留环；只在命令触发时读取，
/// 不参与视图更新，因此不会带来多余的刷新。
@MainActor
final class AppStateLocator {
    static let shared = AppStateLocator()
    weak var state: AppState?

    /// 主窗口起来之前的兜底实例。菜单栏项和迷你播放器不依赖主窗口存在，
    /// 但 SwiftUI 的 `environmentObject` 必须给出一个对象，不能是可选。
    /// 注入之后 `resolved` 就换成真正的那个。
    private lazy var fallback = AppState()
    var resolved: AppState { state ?? fallback }

    private init() {}
}
