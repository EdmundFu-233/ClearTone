import Foundation

/// 侧栏栏目的 ⌘数字快捷键映射。
///
/// ## 为什么单独一个文件
///
/// 规则是纯函数，但用它的 `AppCommands.swift` 被 `project.yml` 排除在单测
/// target 之外（它依赖菜单栏与命令组），所以规则本身必须放在测试编得到的
/// 文件里才有回归测试 —— 照 `Playback/SongTransfer.swift` 的先例。
///
/// ## 这里的坑
///
/// 原来写在 `AppCommands` 里的是
/// `KeyEquivalent(Character("\(index + 1)"))`。而 `Character.init(String)`
/// 遇到**多于一个 extended grapheme cluster** 的字符串会直接
/// `fatalError`（`Swift/Character.swift:177`），不是返回 nil。
///
/// 而 `sidebarPages` 有 **10** 项 —— 第 10 项（`index == 9`）算出的是
/// `"10"`，两个字符，于是**每次启动都崩**在构造菜单命令时。
/// 该代码与 10 个侧栏栏目在同一个提交（`2276684`）里引入，
/// 也就是说它从落地起就没能启动过。
public enum SidebarShortcuts {
    /// 数字键序列：⌘1…⌘9，第 10 个复用 ⌘0。
    ///
    /// 与 `AppState.Page.sidebarPages` 的顺序一一对应。
    public static let digitKeys: [Character] = {
        var keys: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
        keys.append("0")   // 第十个：⌘0（与「显示/隐藏队列」共用，见 AppCommands）
        return keys
    }()

    /// 第 `index` 个侧栏栏目的快捷键字符。
    ///
    /// 返回 nil 表示超出可用数字键的数量 —— 调用方**必须**处理 nil，
    /// 绝不能自己拼字符串：`Character` 遇到多字符会 trap，
    /// 也就是「侧栏加了第 11 个栏目」会变成一起启动崩溃。
    public static func key(forIndex index: Int) -> Character? {
        guard index >= 0, index < digitKeys.count else { return nil }
        return digitKeys[index]
    }
}
