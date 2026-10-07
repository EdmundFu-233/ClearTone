import SwiftUI

@main
struct ClearToneiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState = AppState()
    @StateObject private var player = PlayerController.shared
    @StateObject private var settings = SettingsStore.shared
    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environmentObject(appState)
                .environmentObject(player)
                .environmentObject(settings)
                .tint(IOSTheme.accent)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { Task { await player.persistNow() } }
                }
                .task {
                    AudioCacheManager.shared.isEnabled = UserDefaults.standard.object(forKey: "mobileAudioCacheEnabled") as? Bool ?? true
                    player.setProvider(NeteaseProvider.shared)
                    await appState.restoreLoginState()
                }
        }
    }
}
