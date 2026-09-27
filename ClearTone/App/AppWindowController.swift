import AppKit
import SwiftUI
import Combine

/// 从**没有 SwiftUI 场景上下文**的地方打开窗口：菜单栏的 `NSMenu`、`AppDelegate`。
///
/// `openWindow(id:)` 是 SwiftUI 的 environment action，只能在场景里用。
/// 而菜单栏项装的是 `NSHostingView`（见 `MenuBarController`），
/// 那个 environment 是空的 —— 在里面调 `openWindow` 点了没反应。
/// 所以这两处直接操作 `NSWindow`。
@MainActor
enum AppWindowController {

    /// 主窗口。
    ///
    /// 排除迷你播放器：它也能 become main，混进来会让「打开主窗口」
    /// 把迷你播放器拉到前面。
    ///
    /// 找不到「可见的」窗口时要继续往后找 —— 「继续后台播放」和「缩到菜单栏」
    /// 两档下主窗口是被 `orderOut` 藏起来的（见 `WindowCloseInterceptor`），
    /// 仍然在 `NSApp.windows` 里，直接 `makeKeyAndOrderFront` 就能拉回来。
    static var mainWindow: NSWindow? {
        let candidates = NSApp.windows.filter {
            $0.canBecomeMain && $0 !== MiniPlayerWindowController.shared.window
        }
        return candidates.first { $0.identifier?.rawValue == "main" }
            ?? candidates.first(where: \.isVisible)
            ?? candidates.first
    }

    static func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // 一个应用窗口都不存在（例如窗口在启动前就被销毁过）时的兜底。
        // `文件 ▸ 新建窗口` 的 action 虽然被 AppCommands 换掉了，但仍在响应链上。
        if !NSApp.sendAction(Selector(("newDocument:")), to: nil, from: nil) {
            CTLog.general.error("无法重新创建主窗口")
        }
    }

    static func openMiniPlayer() {
        NSApp.activate(ignoringOtherApps: true)
        MiniPlayerWindowController.shared.show()
    }

    /// 给窗口装上关闭拦截器。可以重复调用，装过的窗口会跳过。
    ///
    /// 迷你播放器**不装**：它的关闭按钮就该真的关掉它。被吞成 `orderOut` 的话，
    /// `MiniPlayerWindowController.window` 会永久持有这个 `NSWindow`、永远不释放。
    static func installCloseInterceptor(on window: NSWindow) {
        guard window !== MiniPlayerWindowController.shared.window else { return }
        // 不能套两层：第二层会把第一层当成 upstream，看起来能工作，
        // 但 orderOut 的语义会被绕回去
        guard !(window.delegate is WindowCloseInterceptor) else { return }
        window.delegate = WindowCloseInterceptor(upstream: window.delegate)
    }
}

extension Notification.Name {
    /// 主窗口被「藏起来」或重新显示。
    ///
    /// `orderOut` 不触发 `NSWindow.willCloseNotification`，所以菜单栏图标
    /// 只能靠这个通知重算显隐。
    static let cleartoneWindowVisibilityChanged = Notification.Name("com.cleartone.windowVisibilityChanged")
}

/// 拦住主窗口的关闭：改成「藏起来」而不是「销毁」。
///
/// 为什么不让窗口真的关掉：
/// 1. 一旦销毁，就再没有 `NSWindow` 可以 `makeKeyAndOrderFront`，拉回来只能靠
///    `newDocument:` 这类间接手段 —— 它能否重建 SwiftUI 的 `WindowGroup`
///    没有公开保证，失败时整个应用再也回不去（菜单栏图标此时可能也是隐藏的）。
/// 2. `.keepPlaying` / `.minimizeToMenuBar` 本来就要求应用继续活着。
/// 3. macOS 上的音乐应用（网易云、Spotify）都是关窗后隐藏，点 Dock 图标即回。
///
/// `.quit` 那一档不拦：那一档就是要销毁窗口并退出。
final class WindowCloseInterceptor: NSObject, NSWindowDelegate {
    /// SwiftUI 自己挂在窗口上的 delegate。其它回调一律转给它 ——
    /// 整个替换掉会让窗口的移动/缩放/工具栏联动失效。
    private weak var upstream: (any NSWindowDelegate)?

    init(upstream: (any NSWindowDelegate)?) {
        self.upstream = upstream
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 先问上游：SwiftUI 自己都不同意关的话不该硬来
        if upstream?.windowShouldClose?(sender) == false { return false }

        guard SettingsStore.shared.settings.closeBehavior != .quit else { return true }
        sender.orderOut(nil)
        NotificationCenter.default.post(
            name: .cleartoneWindowVisibilityChanged, object: sender
        )
        return false
    }

    // NSWindowDelegate 的其它方法全靠这两个转发给上游：
    // 声明成 @objc 的协议方法不实现就会走到 unrecognized selector。
    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(windowShouldClose(_:)) { return true }
        return upstream?.responds(to: aSelector) == true || super.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        aSelector == #selector(windowShouldClose(_:)) ? nil : upstream
    }
}

/// 迷你播放器窗口。自己持有 `NSWindow`，而不是 SwiftUI 的 `Window` 场景。
///
/// 换成自己管有两个原因：
/// 1. 菜单栏要能开迷你播放器（关窗后它和菜单栏图标是仅有的两个入口），
///    而 `Window(id:)` 场景只能靠 `openWindow(id:)`，场景外调不到。
/// 2. 置顶直接设 `NSWindow.level`。原先靠一个 `NSViewRepresentable`
///    在 `DispatchQueue.main.async` 里读 `view.window` —— 那个时机窗口通常
///    还没建好，读到 nil，置顶静默失效，且没有任何报错。
@MainActor
final class MiniPlayerWindowController {
    static let shared = MiniPlayerWindowController()

    /// 迷你播放器的 Autosave 名字：记住上次的位置
    private static let frameAutosaveName = "cleartone-mini-player"

    private(set) var window: NSWindow?
    private var levelSubscription: AnyCancellable?

    private init() {}

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingView(rootView: makeContent())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.title = "迷你播放器"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // 上次的位置优先；没有存档才居中
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        applyLevel(to: window)
        self.window = window

        // 置顶是设置项，随时可能被改：订阅而不是只在建窗时读一次
        levelSubscription = SettingsStore.shared.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyLevel() }

        window.makeKeyAndOrderFront(nil)
        resizeToFitContent()
    }

    private func makeContent() -> some View {
        // 迷你播放器不依赖导航状态，但 View 需要一个 AppState 实例。
        // 主窗口起来后 `resolved` 就是那一个真正的实例。
        MiniPlayerView()
            .environmentObject(PlayerController.shared)
            .environmentObject(SettingsStore.shared)
            .environmentObject(AppStateLocator.shared.resolved)
    }

    /// 内容是固定宽度的 SwiftUI 视图，窗口跟着它量。
    /// 量不出来（首次显示还没布局）就保留 160 的初值，不做成 0 高的窗口。
    private func resizeToFitContent() {
        guard let hosting = window?.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 1, size.height > 1 else { return }
        window?.setContentSize(NSSize(width: ceil(size.width), height: ceil(size.height)))
    }

    private func applyLevel() {
        guard let window else { return }
        applyLevel(to: window)
    }

    private func applyLevel(to window: NSWindow) {
        let level: NSWindow.Level = SettingsStore.shared.settings.miniPlayerAlwaysOnTop
            ? .floating
            : .normal
        // 反复写同值会让 AppKit 重新排序窗口列表
        guard window.level != level else { return }
        window.level = level
    }
}
