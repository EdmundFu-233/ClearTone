import SwiftUI
import AppKit

/// 应用菜单命令
struct AppCommands: Commands {
    @FocusedObject private var appState: AppState?

    var body: some Commands {
        // 文件菜单
        CommandGroup(replacing: .newItem) {}

        // 导航菜单。⌘1…⌘9 依次对应侧栏从「发现音乐」往下的顺序。
        CommandMenu("导航") {
            ForEach(Array(AppState.Page.sidebarPages.enumerated()), id: \.element) { index, page in
                sidebarShortcut(index) {
                    Button(page.rawValue) {
                        appState?.switchToTopLevel(page)
                    }
                }
            }

            Divider()

            // ⌘F 聚焦搜索框。用 Button + 通知而不是自定义 action，
            // 这样系统搜索菜单项仍然可用，且不会抢走输入框里的空格键。
            Button("搜索") { NotificationCenter.default.post(name: .cleartoneFocusSearch, object: nil) }
                .keyboardShortcut("f", modifiers: .command)

            Button("设置…") { appState?.switchToTopLevel(.settings) }
                .keyboardShortcut(",", modifiers: .command)

            Divider()

            // 有返回栈时才启用，菜单项的 disabled 是 macOS 常规做法
            Button("返回") { appState?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(appState?.canGoBack != true)
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

            Button("快进 15 秒") { PlayerController.shared.seek(by: 15) }
                .keyboardShortcut("]", modifiers: .command)

            // ⌘[ 留给「返回」，快退用 ⇧⌘] 以免冲突
            Button("快退 15 秒") { PlayerController.shared.seek(by: -15) }
                .keyboardShortcut("]", modifiers: [.command, .shift])

            Divider()

            Button("音量+") { PlayerController.shared.volume = min(1, PlayerController.shared.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)

            Button("音量-") { PlayerController.shared.volume = max(0, PlayerController.shared.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)

            Divider()

            Button("切换播放模式") { PlayerController.shared.cyclePlayMode() }
                .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("收藏/取消收藏当前歌曲") {
                guard let song = PlayerController.shared.currentSong,
                      let state = AppStateLocator.shared.state else { return }
                Task { @MainActor in await state.toggleLike(song) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(PlayerController.shared.currentSong == nil
                      || AppStateLocator.shared.state?.canPerformWrite != true)

            Divider()

            Button("迷你播放器") { AppWindowController.openMiniPlayer() }
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

    /// 给侧栏按钮挂 ⌘数字快捷键。
    ///
    /// 映射规则在 `SidebarShortcuts`（可测），这里**必须处理 nil**：
    /// 原来直接写 `KeyEquivalent(Character("\(index + 1)"))`，而
    /// `sidebarPages` 有 10 项 —— 第 10 项算出 `"10"`，而
    /// `Character.init(String)` 遇到多于一个 grapheme cluster 是
    /// `fatalError` 不是返回 nil，于是每次启动都崩在构造菜单命令时。
    ///
    /// 数字键不够用时**不挂快捷键**，按钮照常工作。
    @ViewBuilder
    private func sidebarShortcut<Content: View>(
        _ index: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let key = SidebarShortcuts.key(forIndex: index) {
            content().keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            content()
        }
    }
}

extension Notification.Name {
    /// 聚焦搜索框。工具栏的 SearchField 监听它来实现 ⌘F。
    static let cleartoneFocusSearch = Notification.Name("com.cleartone.focusSearch")
}
