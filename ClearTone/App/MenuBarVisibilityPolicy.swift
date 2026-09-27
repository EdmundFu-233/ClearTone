import Foundation

/// 菜单栏图标该不该出现。
///
/// 抽成纯函数：这条规则同时被设置页的说明、菜单栏项的显隐和单元测试消费，
/// 写在视图里就会出现「设置页说缩到菜单栏、图标却一直挂着」这种对不上的状态。
public enum MenuBarVisibilityPolicy {
    /// - Parameters:
    ///   - menuBarAlwaysVisible: 设置里的「菜单栏常驻」
    ///   - closeBehavior: 用户选的关窗行为
    ///   - hasVisibleWindow: 当前是否有可见的普通应用窗口
    public static func showsStatusItem(
        menuBarAlwaysVisible: Bool,
        closeBehavior: AppSettings.CloseBehavior,
        hasVisibleWindow: Bool
    ) -> Bool {
        if menuBarAlwaysVisible { return true }
        // 只有「缩到菜单栏」这一种行为需要靠图标把人捞回来：
        // 「继续后台播放」有 ⌘⇧M 的迷你播放器兜底，
        // 「退出应用」压根不存在「关窗之后」这个状态。
        return closeBehavior == .minimizeToMenuBar && !hasVisibleWindow
    }
}
