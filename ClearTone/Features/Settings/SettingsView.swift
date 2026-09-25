import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var helper: HelperProcessManager
    @ObservedObject private var audioCache = AudioCacheManager.shared
    @Environment(\.colorScheme) var colorScheme
    @State private var showAPIConfig = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CTSpacing.xl) {
                Text(L10n.Common.settings)
                    .font(CTTypography.pageTitle)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))

                // 外观
                SettingsSection(title: L10n.Settings.appearance) {
                    Picker(L10n.Settings.theme, selection: $settings.settings.themeMode) {
                        ForEach(CTThemeMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // 播放
                SettingsSection(title: L10n.Settings.playback) {
                    Toggle(L10n.Settings.resumePlayback, isOn: $settings.settings.resumePlaybackOnLaunch)
                    Text(L10n.Settings.resumePlaybackHint)
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))

                    Picker(L10n.Settings.quality, selection: $settings.settings.preferredQuality) {
                        ForEach(AudioQuality.QualityLevel.allCases, id: \.self) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .onChange(of: settings.settings.preferredQuality) { newValue in
                        // 统一入口：同步到播放器并对当前歌曲立即按新音质重新拉流
                        player.setRequestedQuality(newValue)
                    }

                    Divider()

                    Toggle("缓存播放的音乐（96kbps OPUS）", isOn: $settings.settings.audioCacheEnabled)
                        .onChange(of: settings.settings.audioCacheEnabled) { _, newValue in
                            AudioCacheManager.shared.isEnabled = newValue
                        }
                    Text("听过的网易云歌曲会转成 96kbps OPUS 缓存，再次播放优先使用缓存；受约束 VBR，实际平均码率随内容浮动")
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))

                    HStack {
                        Text("缓存占用：\(audioCache.formattedTotalSize)")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        Spacer()
                        Button("清除缓存") { audioCache.clearAll() }
                            .buttonStyle(.borderless)
                            .disabled(audioCache.totalCacheBytes == 0)
                    }
                }

                // 性能
                SettingsSection(title: L10n.Settings.performance) {
                    Picker(L10n.Settings.performanceMode, selection: $settings.settings.performanceMode) {
                        ForEach(AppSettings.PerformanceMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    Picker(L10n.Settings.spectrum, selection: $settings.settings.spectrumMode) {
                        ForEach(AppSettings.SpectrumMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                }

                // 账号
                SettingsSection(title: "账号") {
                    HStack {
                        Text(appState.isLoggedIn ? (appState.account?.nickname ?? "已登录") : "未登录")
                        if appState.account?.isVIP == true {
                            Text("VIP")
                                .font(CTTypography.caption)
                                .foregroundStyle(CTColors.accent(for: colorScheme))
                        }
                        Spacer()
                        if appState.isLoggedIn {
                            Button("退出登录") { Task { await appState.performLogout() } }
                                .buttonStyle(.borderless)
                        }
                    }
                }

                // 演示模式
                SettingsSection(title: L10n.Settings.demoMode) {
                    Toggle(L10n.Settings.demoMode, isOn: Binding(
                        get: { appState.isDemoMode },
                        set: { appState.setDemoMode($0) }
                    ))
                    Text(L10n.Settings.demoModeHint)
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                }

                // 高级
                SettingsSection(title: L10n.Settings.advanced) {
                    HStack {
                        Text(L10n.Settings.apiServer)
                        Spacer()
                        Button(showAPIConfig ? "隐藏" : "配置") { showAPIConfig.toggle() }
                            .buttonStyle(.borderless)
                    }
                    if showAPIConfig {
                        TextField("http://127.0.0.1:3000", text: $settings.settings.customAPIServer)
                            .textFieldStyle(.roundedBorder)
                        Text(L10n.Settings.apiServerHint)
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    }

                    // 诊断信息
                    VStack(alignment: .leading, spacing: CTSpacing.xs) {
                        Text("诊断信息")
                            .font(CTTypography.bodyMedium)
                        Text("Metal 设备: \(MTLCreateSystemDefaultDevice()?.name ?? "不可用")")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        Text("辅助进程: \(String(describing: helper.state))")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    }
                }

                // 关于
                SettingsSection(title: L10n.Settings.about) {
                    Text("\(L10n.Common.appName) v0.1.0")
                        .font(CTTypography.body)
                    Text("第三方网易云音乐客户端，与网易公司无关联")
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                }
            }
            .padding(CTSpacing.xl)
        }
        .background(CTColors.background(for: colorScheme))
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.colorScheme) var colorScheme

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CTSpacing.md) {
            Text(title)
                .font(CTTypography.sectionTitle)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))
            VStack(alignment: .leading, spacing: CTSpacing.sm) {
                content
            }
            .padding(CTSpacing.lg)
            .background(CTColors.panel(for: colorScheme))
            .cornerRadius(CTRadius.medium)
        }
    }
}
