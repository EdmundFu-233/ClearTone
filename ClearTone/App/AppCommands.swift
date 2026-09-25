import SwiftUI
import AppKit

/// 应用菜单命令
struct AppCommands: Commands {
    @FocusedObject private var appState: AppState?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // 文件菜单
        CommandGroup(replacing: .newItem) {}

        // 导航菜单
        CommandMenu("导航") {
            Button(L10n.Sidebar.discover) { appState?.currentPage = .discover }
                .keyboardShortcut("1", modifiers: .command)
            Button(L10n.Sidebar.search) { appState?.currentPage = .search }
                .keyboardShortcut("2", modifiers: .command)
            Button(L10n.Sidebar.myMusic) { appState?.currentPage = .myMusic }
                .keyboardShortcut("3", modifiers: .command)
            Button(L10n.Sidebar.liked) { appState?.currentPage = .liked }
                .keyboardShortcut("4", modifiers: .command)
        }

        // 播放控制菜单
        CommandMenu("播放") {
            // 不用裸空格：会在搜索框输入时被菜单抢走
            Button("播放/暂停") { PlayerController.shared.togglePlayPause() }
                .keyboardShortcut("p", modifiers: .command)

            Button(L10n.Common.next) { PlayerController.shared.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)

            Button(L10n.Common.previous) { PlayerController.shared.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)

            Divider()

            Button("音量+") { PlayerController.shared.volume = min(1, PlayerController.shared.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)

            Button("音量-") { PlayerController.shared.volume = max(0, PlayerController.shared.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)

            Divider()

            Button("迷你播放器") { openWindow(id: "mini-player") }
                .keyboardShortcut("m", modifiers: [.command, .shift])

            // Cmd+Q 是系统退出，队列用 Cmd+0
            Button("显示/隐藏队列") { appState?.showQueue.toggle() }
                .keyboardShortcut("0", modifiers: .command)
        }

        // 帮助菜单
        CommandGroup(replacing: .help) {
            Button("关于澄音") { NSApp.orderFrontStandardAboutPanel(nil) }
        }
    }
}
