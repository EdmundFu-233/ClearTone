import SwiftUI

struct IOSSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var store: SettingsStore
    @ObservedObject private var cache = AudioCacheManager.shared
    @AppStorage("mobileAudioCacheEnabled") private var cacheEnabled = true
    @State private var confirmLogout = false
    @State private var confirmClear = false
    var body: some View {
        Form {
            Section("账号") {
                if let account = appState.account, appState.isLoggedIn {
                    LabeledContent("网易云音乐", value: account.nickname)
                    Button("退出登录", role: .destructive) { confirmLogout = true }
                } else { Button("登录网易云音乐") { appState.isLoginPresented = true } }
            }
            Section {
                Picker("音质", selection: $store.settings.preferredQuality) {
                    Text("自动（VIP 无损 / 非 VIP 极高）").tag(AudioQuality.QualityLevel.unknown)
                    ForEach(AudioQuality.QualityLevel.allCases.filter { $0 != .unknown }, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("恢复上次播放位置", isOn: $store.settings.resumePlaybackOnLaunch)
            } header: { Text("播放") } footer: { Text("恢复后保持暂停，由你决定何时播放。") }
            Section {
                Toggle("自动缓存完整歌曲", isOn: $cacheEnabled)
                LabeledContent("音频缓存", value: cache.formattedTotalSize)
                Button("清除音频缓存", role: .destructive) { confirmClear = true }
            } header: { Text("缓存") } footer: { Text("自动缓存后可离线播放；最多保留 7 天，上限约 1.5 GB。试听歌曲不会缓存。") }
            Section("关于澄音") {
                LabeledContent("版本", value: "0.1.0")
                Text("网易云原生直连 · 本地文件播放\n支持 iPhone 与 iPad，iOS 17 及以上。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .onChange(of: store.settings.preferredQuality) { _, quality in player.setRequestedQuality(quality) }
        .onChange(of: cacheEnabled) { _, enabled in cache.isEnabled = enabled }
        .confirmationDialog("退出网易云音乐账号？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await appState.performLogout() } }
        }
        .confirmationDialog("清除已缓存的音频？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) { cache.clearAll() }
        }
    }
}
