import AppKit
import SwiftUI
import Combine

/// 菜单栏常驻项。
///
/// 不用 SwiftUI 的 `MenuBarExtra`：那是一旦写进 `App.body` 就**无法在运行时隐藏**的
/// 常驻声明 —— 于是「关窗后缩到菜单栏」根本没得选，图标永远挂在菜单栏上，
/// 设置里的开关只是个装饰。这里自己管 `NSStatusItem`，显隐由
/// `MenuBarVisibilityPolicy` 决定。
///
/// 菜单内容是 `NSHostingView` 装 `MenuBarPlayerView`：`NSMenu` 不会替自定义视图
/// 量尺寸，所以宽度定死、高度在每次打开前按 SwiftUI 的实际高度重设。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()

    private static let contentWidth: CGFloat = 280
    /// SwiftUI 量不出高度时的兜底高度，避免开出一个 0 高的空菜单
    private static let fallbackHeight: CGFloat = 200

    private var statusItem: NSStatusItem?
    private var hostingView: NSView?
    private var cancellables = Set<AnyCancellable>()
    private var observerTokens: [NSObjectProtocol] = []

    private override init() { super.init() }

    /// 启动时调用一次。
    func install() {
        guard cancellables.isEmpty else { return }

        SettingsStore.shared.$settings
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        // 通知回调不在 actor 上，但都挂在 .main 队列上。
        // `assumeIsolated` 让它们同步地跑在主 actor 上：
        // 装拦截器必须在重算显隐之前完成，绕到 Task 里会丢掉这个顺序。
        // 不把 Notification 传进 actor 闭包 —— Swift 6 会判成 sending data race。

        // willClose 触发时窗口还没关掉，此刻判定「有没有可见窗口」会把正在关的
        // 那一个算进去，所以推到下一个 runloop 再算。
        observerTokens.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.async { self?.refresh() }
            }
        })
        // 重新变成前台时窗口状态可能刚变过（从程序坞点回来），要重算
        observerTokens.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        // 主窗口被「藏起来」时不会有 willClose，只能靠这个通知
        observerTokens.append(center.addObserver(
            forName: .cleartoneWindowVisibilityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        // 窗口拿到主键时补装拦截器：用户能点关闭按钮之前一定先拿到过主键，
        // 所以这条通知足以覆盖 SwiftUI 事后重建的窗口。
        observerTokens.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                // 迷你播放器的关闭按钮就该真的关掉它，不能被主窗口的拦截器吞成 orderOut
                AppWindowController.installCloseInterceptor(on: window)
                self?.refresh()
            }
        })

        refresh()
        // 首启动时主窗口可能已经开着了（`applicationDidFinishLaunching` 在窗口显示前后都能触发）
        NSApp.windows.forEach { AppWindowController.installCloseInterceptor(on: $0) }
    }

    private func refresh() {
        let settings = SettingsStore.shared.settings
        let visible = MenuBarVisibilityPolicy.showsStatusItem(
            menuBarAlwaysVisible: settings.menuBarAlwaysVisible,
            closeBehavior: settings.closeBehavior,
            hasVisibleWindow: Self.hasVisibleAppWindow
        )
        let item = ensureStatusItem()
        guard item.isVisible != visible else { return }
        item.isVisible = visible
        // 藏起来时顺手收起已展开的菜单，否则会留一个点不到的空菜单
        if !visible { item.menu?.cancelTracking() }
    }

    /// 是否有可见的普通应用窗口。
    ///
    /// 两条排除规则都必需：
    /// - `canBecomeMain` 排除菜单自身的窗口和各类 panel：它们 `isVisible` 也是 true，
    ///   但用户看不到「有个窗口开着」，把它们算进来会让状态栏图标永远不出现。
    /// - **迷你播放器必须显式排除**。它的 styleMask 是
    ///   `[.titled, .closable, .fullSizeContentView]`，没有 `.nonactivatingPanel`，
    ///   所以 `canBecomeMain == true`、`isVisible == true`。
    ///   不排除的话：开着迷你播放器再关主窗口 → 「还有可见窗口」→ 图标被隐藏，
    ///   而迷你播放器又不是主窗口，用户就从「缩到菜单栏」这条路上被自己关掉了。
    private static var hasVisibleAppWindow: Bool {
        let miniPlayer = MiniPlayerWindowController.shared.window
        return NSApp.windows.contains {
            $0.isVisible && $0.canBecomeMain && $0 !== miniPlayer
        }
    }

    private func ensureStatusItem() -> NSStatusItem {
        if let statusItem { return statusItem }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "澄音")
        item.button?.toolTip = "澄音"
        item.menu = makeMenu()
        // 真正的显隐由 refresh() 决定
        item.isVisible = false
        statusItem = item
        return item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        // 菜单项的可用性由 SwiftUI 侧的 `.disabled` 决定，
        // 让 AppKit 再按 target/action 猜一遍只会把可点的按钮置灰
        menu.autoenablesItems = false

        let root = MenuBarPlayerView(
            onOpenMainWindow: { AppWindowController.openMainWindow() },
            onOpenMiniPlayer: { AppWindowController.openMiniPlayer() },
            onQuit: { NSApp.terminate(nil) }
        )
        .environmentObject(PlayerController.shared)
        .frame(width: Self.contentWidth)

        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: Self.contentWidth, height: Self.fallbackHeight)
        hostingView = host

        let item = NSMenuItem()
        item.view = host
        menu.addItem(item)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let host = hostingView else { return }
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        host.frame = NSRect(
            x: 0,
            y: 0,
            width: Self.contentWidth,
            height: height > 1 ? ceil(height) : Self.fallbackHeight
        )
    }
}
