import SwiftUI

/// 沉浸式正在播放页
struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var appState: AppState

    /// 歌词时间偏移（秒）。正数 = 歌词提前。
    private var lyricOffsetSeconds: TimeInterval { settings.settings.lyricOffset }
    /// 缓存状态变化（正在写 / 写完）要即时反映到音源胶囊上，
    /// 而 PlayerController 不订阅 AudioCacheManager，所以由视图自己观察
    @ObservedObject private var audioCache = AudioCacheManager.shared
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss

    @State private var lyrics: [LyricLine] = []
    @State private var currentLineIndex: Int?
    /// 逐字高亮要用的「当前播放位置」。跟着 0.1s 定时器一起更新，
    /// 不单独订阅 —— 已经是 0.1s 一跳了，再加一路只是多一次 @Published。
    @State private var wordClock: TimeInterval = 0
    @State private var isPureMusic = false
    @State private var hasWordTiming = false
    @State private var showTranslation = true
    @State private var showRomanization = false
    @State private var userScrolling = false

    @State private var coverColors: [Color] = [
        Color(hex: 0x1a1a2e), Color(hex: 0x16213e), Color(hex: 0x0f3460),
        Color(hex: 0x533483), Color(hex: 0xe94560)
    ]
      @State private var spectrum: [Float] = Array(repeating: 0, count: SpectrumProcessor.bandCount)
      @State private var isAnimating = true
      @State private var lyricsTask: Task<Void, Never>?
      /// App 是否在前台。原先 isAnimating 声明后从未被置为 false，
      /// 导致打开正在播放页后即使 App 在后台 Metal 循环也不停
      @Environment(\.scenePhase) private var scenePhase

    // 歌词行高亮定时器：@State 保证视图身份内只创建一次，
    // 由 SwiftUI 订阅生命周期管理，退出视图自动失效，避免 Timer 堆积
    @State private var lyricTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 底色：**不透明**的深色，永远在最下层。
                //
                // 这一层不是装饰，是可读性的保证。原来的写法把可读性押在
                // Metal 背景「一定会画出来」上，但那条路有几种失败方式：
                // 1. 无 Metal 设备 / pipelineState 创建失败 → 什么都没画；
                // 2. view.isPaused 或首帧未提交 → 短暂空白；
                // 3. 未来若真的按 spec 做封面取色，浅色封面会算出浅色背景。
                // 任何一种情况下，页面里那些**硬编码的 .white 文字**就会变成
                // 「白底白字」——用户在浅色主题下报告的正是这个。
                // 有了这层不透明底色，文字对比度就不再依赖任何背景层的成败。
                CTColors.immersiveBase
                    .ignoresSafeArea()

                // Metal 动态背景
                if settings.settings.performanceMode != .static_ {
                    MetalBackgroundView(
                        colors: $coverColors,
                        spectrum: $spectrum,
                        isAnimating: $isAnimating,
                        showSpectrum: .constant(settings.settings.spectrumMode != .off),
                        renderScale: settings.settings.performanceMode == .saver ? 0.3 : 0.6
                    )
                    .ignoresSafeArea()
                } else {
                    // 静态背景
                    LinearGradient(
                        colors: coverColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                }

                // 内容
                HStack(spacing: 0) {
                    // 左侧：封面与信息
                    VStack(spacing: CTSpacing.xl) {
                        Spacer()

                        // 封面
                        CoverImage(
                            url: player.currentSong?.coverURL,
                            size: min(geometry.size.width * 0.35, 400),
                            contentMode: .fit
                        ) {
                            RoundedRectangle(cornerRadius: CTRadius.large)
                                .fill(CTColors.overlay(for: colorScheme))
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.system(size: 60))
                                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                                )
                        }
                        .frame(width: min(geometry.size.width * 0.35, 400))
                        .aspectRatio(1, contentMode: .fit)
                        .cornerRadius(CTRadius.large)
                        .shadow(radius: 20)

                        // 曲目信息
                        VStack(spacing: CTSpacing.sm) {
                            HStack(spacing: CTSpacing.md) {
                                Text(player.currentSong?.title ?? "未知歌曲")
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundStyle(.white)

                                if let song = player.currentSong, song.source == .netease {
                                    Button(action: { Task { await appState.toggleLike(song) } }) {
                                        Image(systemName: appState.isLiked(song.id) ? "heart.fill" : "heart")
                                            .font(.title2)
                                            .foregroundStyle(appState.isLiked(song.id) ? CTColors.accent(for: colorScheme) : .white.opacity(0.8))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!appState.isLoggedIn)
                                    .help(appState.isLiked(song.id) ? "取消收藏" : "收藏到喜欢的音乐")
                                    .accessibilityLabel(appState.isLiked(song.id) ? "取消收藏" : "收藏")
                                }
                            }

                            Text(player.currentSong?.artistNames ?? "未知艺术家")
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.8))

                            // 音源信息：主文案是此刻真正在放的格式/码率，
                            // 缓存状态只是旁边的弱化图标（第一次听的歌播的是在线流，
                            // 此刻显示的码率必须和耳朵听到的一致）
                            if let info = player.playingSourceInfo, let song = player.currentSong {
                                let pill = HStack(spacing: 6) {
                                    if info.isFromCache {
                                        Image(systemName: "internaldrive.fill")
                                    }
                                    Text(info.text)
                                        .lineLimit(1)
                                    if !info.isFromCache {
                                        switch info.cache {
                                        case .cached: Image(systemName: "internaldrive")
                                        case .caching: Image(systemName: "arrow.down.circle")
                                        case .none: EmptyView()
                                        }
                                    }
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(.white.opacity(0.16), in: Capsule())

                                if song.source == .netease {
                                    // 同一首歌的音质入口：点胶囊选无损/Hi-Res → 走网易源、跳过缓存
                                    SongQualityMenu(
                                        songID: song.id,
                                        help: info.detail + "\n\n点击为这首歌指定音质"
                                    ) { pill }
                                } else {
                                    pill.help(info.detail)
                                }
                            }
                        }

                        // 控制
                        HStack(spacing: CTSpacing.xl) {
                            Button(action: { player.previous() }) {
                                Image(systemName: "backward.fill")
                                    .font(.title)
                            }
                            Button(action: { player.togglePlayPause() }) {
                                Image(systemName: player.playbackState.isPlayIntentActive ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 64))
                            }
                            Button(action: { player.next() }) {
                                Image(systemName: "forward.fill")
                                    .font(.title)
                            }
                        }
                        .foregroundStyle(.white)

                        // 进度。局部订阅播放进度，拖动中只预览、抬手才提交。
                        //
                        // 内容**只**放进 observingPlaybackTime 的闭包：那个函数会丢弃
                        // 接收者 self，写在它前面的内容不会被替换掉，而是同时渲染 ——
                        // 之前这里多写了一个 `nowPlayingProgress(time: 0)`，
                        // 于是正在播放页有两条进度条，上面的时间恒为 0:00
                        // 却仍是可拖动的真 Slider。
                        observingPlaybackTime(player) { currentTime in
                            VStack(spacing: CTSpacing.xs) {
                                nowPlayingProgress(time: currentTime)
                            }
                            .frame(width: min(geometry.size.width * 0.35, 400))
                        }
                        .onChange(of: isProgressDragging) { _, dragging in
                            if !dragging { player.commitSeek(to: player.currentTime) }
                        }

                        Spacer()
                    }
                    .frame(width: geometry.size.width * 0.45)
                    .padding()

                    // 右侧：歌词
                    VStack {
                        // 歌词工具栏
                        HStack {
                            Toggle("翻译", isOn: $showTranslation)
                                .toggleStyle(.button)
                                .font(CTTypography.caption)

                            Toggle("音译", isOn: $showRomanization)
                                .toggleStyle(.button)
                                .font(CTTypography.caption)

                            Spacer()

                            // 歌词偏移。放在歌词页而不是设置页：
                            // 「这首歌字幕早了 0.3 秒」这种调整几乎总是
                            // 看着当前这首歌做的，放到设置里等于让人盲调。
                            LyricOffsetControl()

                            if userScrolling {
                                Button(action: { userScrolling = false }) {
                                    Label(L10n.Player.backToCurrent, systemImage: "arrow.down.circle")
                                        .font(CTTypography.caption)
                                }
                            }
                        }
                        .padding()
                        .foregroundStyle(.white)

                        // 歌词列表
                        if isPureMusic {
                            Spacer()
                            Text(L10n.Player.pureMusic)
                                .font(CTTypography.sectionTitle)
                                .foregroundStyle(.white.opacity(0.6))
                            Spacer()
                        } else if lyrics.isEmpty {
                            Spacer()
                            Text(L10n.Player.noLyrics)
                                .font(CTTypography.sectionTitle)
                                .foregroundStyle(.white.opacity(0.6))
                            Spacer()
                        } else {
                            LyricListView(
                                lyrics: lyrics,
                                currentIndex: currentLineIndex,
                                currentTime: wordClock,
                                showTranslation: showTranslation,
                                showRomanization: showRomanization,
                                userScrolling: $userScrolling,
                                onSeek: { time in player.seek(to: time) }
                            )
                        }
                    }
                    .frame(width: geometry.size.width * 0.55)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        // 强制深色外观：Slider / Toggle / Button 这些系统控件会跟着当前
        // colorScheme 渲染，浅色主题下它们是深色控件，压在深色背景上同样看不见。
        // 只靠「把文字设成白色」不够 —— 系统控件的配色不受我们控制。
        .colorScheme(.dark)
        .background(CTColors.immersiveBase)
        // 关闭按钮放左上：左栏顶部是 Spacer 空区，而右上被歌词工具栏占着
        // （翻译/音译开关 + 偏移控件）。
        .overlay(alignment: .topLeading) {
            CTCloseButton(onClose: { dismiss() }, onDarkBackground: true)
                .padding(CTSpacing.lg)
        }
        .onAppear {
            loadLyrics()
        }
        .onDisappear {
            lyricsTask?.cancel()
            lyricsTask = nil
        }
        // 视图不可见或 App 退到后台时停掉 Metal 渲染循环
        .onChange(of: scenePhase) { _, phase in
            isAnimating = phase == .active
        }
        .onChange(of: player.currentSong) { _, _ in
            loadLyrics()
        }
        // 0.1s 轮询歌词行高亮（订阅制，视图销毁自动取消，不会泄漏）
        .onReceive(lyricTimer) { _ in
            // 偏移读全局设置而不是本地 @State —— 原先用 @State 恒为 0，
            // 于是 `AppSettings.lyricOffset` 存了、设置页也准备加控件了，
            // 但**没有任何代码读它**，用户调不动、存下来也没人用。
            // 偏移后的播放位置，供逐字高亮与点击 seek 共用
            wordClock = player.currentTime + lyricOffsetSeconds
            let index = LRCParser.currentLineIndex(
                in: lyrics, at: player.currentTime, offset: lyricOffsetSeconds
            )
            if index != currentLineIndex {
                currentLineIndex = index
            }
        }
        // 注：频谱数据源（MTAudioProcessingTap）已移除 —— 它会让本地 OPUS 缓存
        // 播放卡在「缓冲中」。spectrum 保持全零，Metal 走环境动画回退。
    }

    private func loadLyrics() {
        guard let song = player.currentSong else { return }
        // 取消上一次歌词请求：快速切歌时旧响应用歌曲身份校验丢弃
        lyricsTask?.cancel()
        let songID = song.id
        lyrics = []
        currentLineIndex = nil
        isPureMusic = false
        hasWordTiming = false

        lyricsTask = Task {
            do {
                let result = try await Self.fetchLyrics(for: song)
                guard !Task.isCancelled, player.currentSong?.id == songID else { return }
                lyrics = result.lines
                isPureMusic = result.isPureMusic
                hasWordTiming = result.hasWordTiming
            } catch {
                guard !Task.isCancelled, player.currentSong?.id == songID else { return }
                lyrics = []
                isPureMusic = false
            }
        }
    }

    /// 按歌曲来源选择歌词 Provider（本地歌曲不应打到网易云接口）
    private static func fetchLyrics(for song: Song) async throws -> LyricResult {
        switch song.source {
        case .local:
            return try await LocalProvider.shared.fetchLyrics(songID: song.id)
        case .netease:
            return try await NeteaseProvider.shared.fetchLyrics(songID: song.id)
        }
    }

    /// 进度条是否正在被拖动
    @State private var isProgressDragging = false

    @ViewBuilder
    private func nowPlayingProgress(time: TimeInterval) -> some View {
        ProgressSlider(
            value: Binding(
                get: { time },
                set: { newValue in
                    isProgressDragging ? player.previewSeek(to: newValue) : player.commitSeek(to: newValue)
                }
            ),
            maximum: max(player.duration, 1),
            buffered: player.bufferedTime,
            onEditingChanged: { isProgressDragging = $0 }
        )
        .frame(height: 4)

        HStack {
            Text(formatTime(time))
            Spacer()
            Text(formatTime(player.duration))
        }
        .font(CTTypography.caption)
        .foregroundStyle(.white.opacity(0.7))
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - 歌词列表
struct LyricListView: View {
    let lyrics: [LyricLine]
    let currentIndex: Int?
    /// 已叠加偏移的播放位置，逐字高亮用它
    let currentTime: TimeInterval
    let showTranslation: Bool
    let showRomanization: Bool
    @Binding var userScrolling: Bool
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: CTSpacing.lg) {
                    ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                        LyricLineView(
                            line: line,
                            isCurrent: index == currentIndex,
                            currentTime: currentTime,
                            showTranslation: showTranslation,
                            showRomanization: showRomanization,
                            onTap: { onSeek(line.time) }
                        )
                        .id(index)
                    }
                }
                .padding()
            }
            .onChange(of: currentIndex) { _, newIndex in
                guard !userScrolling, let index = newIndex else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .simultaneousGesture(
                DragGesture().onChanged { _ in userScrolling = true }
            )
        }
    }
}



// MARK: - 逐字（YRC）渲染

/// 歌词行。
///
/// 有逐字时间（YRC）时把一行拆成若干片段，当前时刻之前的片段高亮。
/// **只在真的拿到逐字时间时才这么做** —— 没有数据时用整行高亮，
/// 绝不按字数平均分配时间「伪造」逐字效果（spec §3.4 明确禁止）。
struct LyricLineView: View {
    let line: LyricLine
    let isCurrent: Bool
    /// 已叠加偏移的播放位置
    let currentTime: TimeInterval
    let showTranslation: Bool
    let showRomanization: Bool
    let onTap: () -> Void

    @Environment(\.colorScheme) var colorScheme

    /// 逐字高亮是否可用：当前行 + 有逐字时间 + 至少一个字
    private var supportsWordTiming: Bool {
        isCurrent && !(line.words ?? []).isEmpty
    }

    var body: some View {
        VStack(spacing: CTSpacing.xs) {
            if supportsWordTiming {
                // 逐字：已唱过的部分实心，未唱的部分半透明
                wordTimedText
            } else {
                Text(line.text)
                    .font(isCurrent ? .system(size: 20, weight: .semibold) : .system(size: 16))
                    .foregroundStyle(isCurrent ? .white : .white.opacity(0.5))
            }

            if showTranslation, let translation = line.translation {
                Text(translation)
                    .font(.system(size: 14))
                    .foregroundStyle(isCurrent ? .white.opacity(0.8) : .white.opacity(0.3))
            }

            if showRomanization, let romanization = line.romanization {
                Text(romanization)
                    .font(.system(size: 14))
                    .foregroundStyle(isCurrent ? .white.opacity(0.8) : .white.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    /// 逐字高亮文本。
    ///
    /// 用 `HStack(spacing: 0)` 拼接而不是 `Text` 拼接：中文逐字之间
    /// 不能有额外间距（`Text` + `+` 会按字体的 advance 走，中文里常常多出缝）。
    private var wordTimedText: some View {
        let words = line.words ?? []
        return HStack(spacing: 0) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                Text(word.text)
                    .foregroundStyle(word.time <= currentTime ? .white : .white.opacity(0.4))
            }
        }
        .font(.system(size: 20, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
    }
}
