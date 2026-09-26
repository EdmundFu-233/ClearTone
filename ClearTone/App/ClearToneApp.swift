import SwiftUI

@main
struct ClearToneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var player = PlayerController.shared
    @StateObject private var helper = HelperProcessManager.shared
    @StateObject private var appState = AppState()
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(player)
                .environmentObject(helper)
                .environmentObject(appState)
                .environmentObject(settings)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    appDelegate.appState = appState
                    appDelegate.player = player
                    AudioCacheManager.shared.isEnabled = settings.settings.audioCacheEnabled
                    // 演示音频生成放后台：6 个 30 秒 WAV 合成约 530 万次 sin()，
                    // 放在 App.init 会阻塞主线程数秒导致白屏
                    Task.detached(priority: .utility) {
                        await DemoProvider.ensureDemoAudio()
                    }
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

        // 迷你播放器窗口
        Window("迷你播放器", id: "mini-player") {
            MiniPlayerView()
                .environmentObject(player)
                .environmentObject(settings)
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    var player: PlayerController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动辅助进程
        Task { @MainActor in
            try? await HelperProcessManager.shared.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 默认关窗后继续播放，Cmd+Q 退出
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 先保存最新队列与进度，再停止辅助进程
        player?.persistNow()
        HelperProcessManager.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // 重新打开主窗口
            for window in sender.windows {
                if window.identifier?.rawValue == "main" || window.title.contains("澄音") {
                    window.makeKeyAndOrderFront(nil)
                    return true
                }
            }
            // 没有窗口则新建
            if let window = sender.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}

/// 全局应用状态
/// 设置存储
@MainActor
public class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { PersistenceStore.shared.saveSetting(settings, forKey: "appSettings") }
    }

    public init() {
        self.settings = PersistenceStore.shared.loadSetting(forKey: "appSettings", as: AppSettings.self) ?? AppSettings()
    }
}
