import XCTest
@testable import ClearTone

/// 侧栏 ⌘数字快捷键映射。
///
/// ## 这条测试是被一次真实崩溃逼出来的
///
/// `AppCommands.swift` 原来写的是 `KeyEquivalent(Character("\(index + 1)"))`。
/// `Character.init(String)` 遇到多于一个 extended grapheme cluster 会
/// **fatalError**（`Swift/Character.swift:177`），不是返回 nil；
/// 而 `sidebarPages` 恰好有 10 项，第 10 项算出 `"10"` —— 每次启动都在
/// 构造菜单命令时崩溃。
///
/// 编译期完全正常（`AppCommands.swift` 还被排除在单测 target 外），
/// 只有真的把 App 跑起来才会炸。所以规则被挪到 `SidebarShortcuts`
/// （在测试范围内），并用下面这几条锁住。
@MainActor
final class SidebarShortcutsTests: XCTestCase {

    func testFirstNineSidebarPagesUseOneThroughNine() {
        for index in 0..<9 {
            XCTAssertEqual(
                SidebarShortcuts.key(forIndex: index),
                Character("\(index + 1)"),
                "第 \(index + 1) 个栏目应当是 ⌘\(index + 1)"
            )
        }
    }

    /// 第十个用 ⌘0。
    ///
    /// 这一条就是崩溃点：`"\(9 + 1)"` 是 `"10"`，`Character("10")` 直接 trap。
    func testTenthSidebarPageReusesZeroInsteadOfFormingCharacterFromTen() {
        XCTAssertEqual(SidebarShortcuts.key(forIndex: 9), Character("0"))
    }

    /// 每个侧栏栏目都必须拿得到快捷键。
    ///
    /// 侧栏将来加到第 11 项时，这条会先红，提示需要扩 `digitKeys` ——
    /// 而不是等到启动崩溃。
    func testEverySidebarPageHasAKey() {
        let count = AppState.Page.sidebarPages.count
        XCTAssertGreaterThanOrEqual(count, 10, "侧栏现有 10 个栏目")
        for index in 0..<count {
            XCTAssertNotNil(
                SidebarShortcuts.key(forIndex: index),
                "第 \(index + 1) 个侧栏栏目（\(AppState.Page.sidebarPages[index].rawValue)）没有快捷键"
            )
        }
    }

    /// 超出可用数字键时返回 nil，**由调用方跳过**而不是崩。
    /// 这是「侧栏加了第 11 个栏目」的唯一防线。
    func testOutOfRangeIndexReturnsNilInsteadOfTrapping() {
        XCTAssertNil(SidebarShortcuts.key(forIndex: -1))
        XCTAssertNil(SidebarShortcuts.key(forIndex: 10))
        XCTAssertNil(SidebarShortcuts.key(forIndex: 999))
    }

    /// 每个键都必须是**单个** grapheme cluster。
    /// 直接对 `Character` 的构造前提做断言，而不是间接相信调用方。
    func testAllKeysAreSingleGraphemeClusters() {
        XCTAssertEqual(SidebarShortcuts.digitKeys.count, 10)
        for key in SidebarShortcuts.digitKeys {
            XCTAssertEqual(String(key).count, 1, "键 \(key) 不是单字符")
            XCTAssertEqual(
                Array("\(key)").count, 1,
                "键 \(key) 展开后有多个 grapheme cluster，会让 Character 初始化 trap"
            )
        }
    }

    /// ⌘0 不能与「显示/隐藏队列」重复之外的键冲突：数字键必须唯一，
    /// 否则两个菜单项抢同一个快捷键，有一个永远不生效。
    func testDigitKeysAreUnique() {
        XCTAssertEqual(Set(SidebarShortcuts.digitKeys).count, SidebarShortcuts.digitKeys.count)
    }
}
