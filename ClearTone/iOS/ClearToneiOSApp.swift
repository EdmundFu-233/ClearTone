import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

/// iOS 版入口。
///
/// 与 macOS 版的差异集中在四处：
/// 1. **没有辅助进程** —— `NeteaseProvider` 在 iOS 走 `#if os(iOS)` 分支直连，
///    加密由 `NeteaseCrypto` 原生完成。
/// 2. **没有缓存目录权限申请** —— iOS 沙盒里 `Application Support` 直接可写。
/// 3. **后台音频** —— 配好 `AVAudioSession`，锁屏/切后台继续播放。
/// 4. **没有 Metal 环境背景** —— `AmbientBackgroundRenderer` 依赖
///    `NSViewRepresentable`，iOS 侧用渐变替代。
@main
struct ClearToneiOSApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var player = PlayerController.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(appState)
                .environmentObject(player)
                .task {
                    await appState.restoreLoginState()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // 切后台时暂停高频 UI 更新；音频继续（info.plist 已声明 audio 模式）
            player.setScenePhase(ScenePhaseBridge(phase))
        }
    }

    /// 后台播放：必须声明 `.playback` 类别，否则锁屏后音频会被系统暂停
    private func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // 失败不阻断启动 —— 音频会话配置失败时应用仍可用于浏览
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        #endif
    }
}

/// 底部标签栏
struct RootTabView: View {
    @EnvironmentObject private var player: PlayerController
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            DiscoverPage()
                .tabItem { Label("发现", systemImage: "music.note.house") }
                .tag(0)

            MyMusicPage()
                .tabItem { Label("我的", systemImage: "music.note.list") }
                .tag(1)

            SearchPage()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(2)

            RadioPage()
                .tabItem { Label("电台", systemImage: "waveform") }
                .tag(3)
        }
        .safeAreaInset(edge: .bottom) {
            MiniPlayerBar()
        }
    }
}
