import SwiftUI

struct IOSSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var store: SettingsStore
    @ObservedObject private var cache = AudioCacheManager.shared
    @AppStorage("mobileAudioCacheEnabled") private var cacheEnabled = true
    @State private var confirmLogout = false
    @State private var confirmClear = false
    @State private var isCheckingUpdates = false
    @State private var updateMessage: String?
    @State private var updatePageURL: URL?

    /// 版本号读 Info.plist（project.yml 的 MARKETING_VERSION 是唯一来源）
    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "未知"
    }
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
                Toggle("启动时保留上次播放进度", isOn: $store.settings.resumePlaybackOnLaunch)
            } header: { Text("播放") } footer: { Text("不会自动播放。点击播放后从上次的位置继续；关闭时从头播放。") }
            Section {
                Toggle("自动缓存完整歌曲", isOn: $cacheEnabled)
                LabeledContent("音频缓存", value: cache.formattedTotalSize)
                Button("清除音频缓存", role: .destructive) { confirmClear = true }
            } header: { Text("缓存") } footer: { Text("自动缓存后可离线播放；最多保留 7 天，上限约 1.5 GB。试听歌曲不会缓存。") }
            Section("关于澄音") {
                LabeledContent("版本", value: appVersion)
                Button(isCheckingUpdates ? "检查中…" : "检查更新") { checkForUpdates() }
                    .disabled(isCheckingUpdates)
                if let message = updateMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                if let url = updatePageURL {
                    Link("打开发布页", destination: url)
                }
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

    /// 检查 GitHub Releases 最新稳定版（与 Windows / macOS 同一套语义与文案）
    private func checkForUpdates() {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        updateMessage = "正在检查更新…"
        updatePageURL = nil
        Task {
            defer { isCheckingUpdates = false }
            do {
                let release = try await ReleaseChecker.latestRelease()
                guard ReleaseChecker.isNewer(release.version, than: appVersion) else {
                    updateMessage = "已是最新版本（\(appVersion)）。"
                    return
                }
                if let asset = ReleaseChecker.platformAsset(in: release) {
                    updateMessage = "发现新版本 \(release.version)，可前往下载。"
                    updatePageURL = asset.downloadURL
                } else {
                    updateMessage = "发现新版本 \(release.version)，但暂无 iOS 安装包。"
                    updatePageURL = release.pageURL
                }
            } catch {
                updateMessage = (error as? LocalizedError)?.errorDescription ?? "检查更新失败，请稍后重试。"
            }
        }
    }
}
