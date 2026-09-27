import SwiftUI

@main
struct ClearToneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var player = PlayerController.shared
    @StateObject private var helper = HelperProcessManager.shared
    @StateObject private var appState = AppState()
    /// 全应用共用一个 `SettingsStore`：菜单栏项和迷你播放器都要读设置，
    /// 各自持有一份的话两份会互相覆盖（后写的赢，先写的丢）
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(player)
                .environmentObject(helper)
                .environmentObject(appState)
                .environmentObject(settings)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    AppStateLocator.shared.state = appState
                    appDelegate.appState = appState
                    appDelegate.player = player
                    AudioCacheManager.shared.isEnabled = settings.settings.audioCacheEnabled
                    Task { @MainActor in
                        await appState.restoreLoginState()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .commands {
            AppCommands()
        }

        // 迷你播放器（`MiniPlayerWindowController`）与菜单栏项（`MenuBarController`）
        // 都不在这里声明：它们必须能在运行时显隐/新建，`Scene` 做不到。
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    var player: PlayerController?
    /// 是否走了 `terminateLater` 异步退出协议。决定 `applicationWillTerminate`
    /// 是兜底还是重复劳动。
    private var pendingTerminateReply = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarController.shared.install()
        // 启动辅助进程
        Task { @MainActor in
            try? await HelperProcessManager.shared.start()
        }
    }

    /// 关窗行为由设置决定。原先硬编码 `false`（关窗后继续播放），
    /// 对应的选择器在设置页里并不存在 —— 用户无法改变这个行为。
    ///
    /// 只在「退出应用」这一档返回 true。返回 false 时应用继续在后台跑，
    /// 是不是要看菜单栏图标由 `MenuBarController` 按 `AppSettings` 决定。
    @MainActor
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        SettingsStore.shared.settings.closeBehavior == .quit
    }

    /// 把落盘放到退出流程里同步等待。
    ///
    /// `applicationWillTerminate` 里直接写盘是**来不及**的：它返回后 AppKit
    /// 立刻结束进程，异步编码/写盘任务基本没机会跑完。所以走
    /// `terminateLater` 协议：先告诉系统「稍后终止」，await 落盘，再回复。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        pendingTerminateReply = true
        Task { @MainActor in
            await player?.persistNow()
            HelperProcessManager.shared.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 正常路径已经在 applicationShouldTerminate 里落盘并停掉了辅助进程。
        // 这里只兜底那些没走 terminateLater 的强制退出（例如被强杀时的
        // applicationWillTerminate 回调），重复调用是幂等的。
        if !pendingTerminateReply {
            Task { @MainActor in await player?.persistNow() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 没有可见窗口时从程序坞/启动台点回来：把主窗口拉出来
        if !flag { AppWindowController.openMainWindow() }
        return true
    }
}
