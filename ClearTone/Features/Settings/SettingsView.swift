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
                    Text("默认音质。只对「本地没有缓存、必须走在线流」时生效；要让某一首固定用某个音质（并跳过缓存），在播放栏或正在播放页点音源标签。")
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))

                    Divider()

                    Toggle("缓存播放的音乐（96kbps OPUS）", isOn: $settings.settings.audioCacheEnabled)
                        .onChange(of: settings.settings.audioCacheEnabled) { _, newValue in
                            AudioCacheManager.shared.isEnabled = newValue
                        }
                    Text("听过的网易云歌曲会转成 96kbps OPUS 缓存，再次播放优先使用缓存（默认走缓存，秒开）；受约束 VBR，实际平均码率随内容浮动。缓存码率低于标准档，想听无损/Hi-Res 时在播放栏或正在播放页点音源标签，给这一首指定音质，那次就走网易源、不吃缓存。")
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

                // 账号凭据
                SettingsSection(title: "登录凭据") {
                    Picker("保存位置", selection: Binding(
                        get: { KeychainStore.storageMode },
                        set: { newValue in
                            KeychainStore.storageMode = newValue
                            // 只清内存缓存，已保存的凭据保持不动；
                            // 下次读取会按新位置加载，并自动把钥匙串里的旧凭据迁移过来
                            KeychainStore.shared.invalidateCache()
                        }
                    )) {
                        ForEach(KeychainStore.StorageMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Text("钥匙串会把凭据绑定到 App 的代码签名，每次重新构建后签名变化，就会反复弹「输入密码以访问钥匙串」。选「本地文件」可彻底避免，代价是 Cookie 以明文存在本机。")
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    if KeychainStore.storageMode == .plaintextFile {
                        Text("文件位置：\(PlaintextCredentialStore.shared.path)")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            .textSelection(.enabled)
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
                    .help("背景呈现方式。真实频谱需要读取音频采样，\n"
                          + "当前播放链路拿不到，因此不提供该选项。")
                }

                // 窗口与关闭行为
                SettingsSection(title: "窗口") {
                    Picker("关闭窗口时", selection: $settings.settings.closeBehavior) {
                        ForEach(AppSettings.CloseBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .help(settings.settings.closeBehavior.help)

                    Toggle("菜单栏常驻", isOn: $settings.settings.menuBarAlwaysVisible)
                        .toggleStyle(.switch)
                        .help("只要应用在运行就显示菜单栏图标，不受「关闭窗口时」影响。\n"
                              + "关掉它时，图标只在选了「缩到菜单栏」且当前没有窗口时出现。")

                    Toggle("迷你播放器置顶", isOn: $settings.settings.miniPlayerAlwaysOnTop)
                        .toggleStyle(.switch)
                }

                // 歌词
                SettingsSection(title: "歌词") {
                    HStack {
                        Text("时间偏移")
                        Spacer()
                        Text(offsetDescription)
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            .monospacedDigit()
                    }
                    Text("字幕比音频早/晚时在这里微调，也可以在正在播放页直接调。")
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
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

                // 高级
                SettingsSection(title: L10n.Settings.advanced) {
                    HStack {
                        Text(L10n.Settings.apiServer)
                        Spacer()
                        Button(showAPIConfig ? "隐藏" : "配置") { showAPIConfig.toggle() }
                            .buttonStyle(.borderless)
                    }
                    if showAPIConfig {
                        // 明确写成「未接线」，而不是留一个可编辑的输入框。
                        //
                        // 原先这里是个能打字、能保存、但**没有任何代码读取**的
                        // TextField：`customAPIServer` 在整个工程里只出现在
                        // 设置模型和这个控件里。辅助进程地址是
                        // HelperProcessManager 自己生成的随机端口（安全模型要求
                        // 每次启动都换），没法从设置里指定。
                        // spec §8「每个可点按钮都必须能用」与 §13「不做空壳按钮」
                        // 都禁止这种控件，所以改成只读的说明文字。
                        Text("未接线")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.accent(for: colorScheme))
                        Text("辅助进程地址由应用在启动时自动分配（随机端口 + 一次性令牌），"
                             + "不接受外部指定 —— 这是安全模型的一部分，不是一个待填的空框。")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
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

    /// 偏移的可读描述。与歌词页的显示规则保持一致。
    private var offsetDescription: String {
        let value = settings.settings.lyricOffset
        guard abs(value) >= 0.001 else { return "0.0 秒" }
        return value > 0
            ? String(format: "提前 %.1f 秒", value)
            : String(format: "延后 %.1f 秒", -value)
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
