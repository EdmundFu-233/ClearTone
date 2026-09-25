import SwiftUI

/// 沉浸式正在播放页
struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var appState: AppState
    @ObservedObject private var audioCache = AudioCacheManager.shared
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss

    @State private var lyrics: [LyricLine] = []
    @State private var currentLineIndex: Int?
    @State private var isPureMusic = false
    @State private var hasWordTiming = false
    @State private var showTranslation = true
    @State private var showRomanization = false
    @State private var userScrolling = false
    @State private var lyricOffset: TimeInterval = 0

    @State private var coverColors: [Color] = [
        Color(hex: 0x1a1a2e), Color(hex: 0x16213e), Color(hex: 0x0f3460),
        Color(hex: 0x533483), Color(hex: 0xe94560)
    ]
    @State private var spectrum: [Float] = Array(repeating: 0, count: 64)
    @State private var isAnimating = true
    @State private var lyricsTask: Task<Void, Never>?

    // 歌词行高亮定时器：@State 保证视图身份内只创建一次，
    // 由 SwiftUI 订阅生命周期管理，退出视图自动失效，避免 Timer 堆积
    @State private var lyricTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
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
                                    .disabled(!appState.isLoggedIn || appState.isDemoMode)
                                    .help(appState.isLiked(song.id) ? "取消收藏" : "收藏到喜欢的音乐")
                                    .accessibilityLabel(appState.isLiked(song.id) ? "取消收藏" : "收藏")
                                }
                            }

                            Text(player.currentSong?.artistNames ?? "未知艺术家")
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.8))

                            // 缓存提示（格式 + 实际码率，只要有缓存就显示）
                            if let song = player.currentSong,
                               let meta = audioCache.meta(for: song.id) {
                                Text(player.isCurrentFromCache
                                     ? "播放缓存 · \(meta.formatName) \(meta.bitrateKbps)kbps"
                                     : "已缓存 · \(meta.formatName) \(meta.bitrateKbps)kbps")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3)
                                    .background(.white.opacity(0.16), in: Capsule())
                                    .help(player.isCurrentFromCache ? "正在播放本地缓存，优先于在线流" : "本地已有缓存，下次播放优先使用")
                            }
                        }

                        // 控制
                        HStack(spacing: CTSpacing.xl) {
                            Button(action: { player.previous() }) {
                                Image(systemName: "backward.fill")
                                    .font(.title)
                            }
                            Button(action: { player.togglePlayPause() }) {
                                Image(systemName: player.playbackState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 64))
                            }
                            Button(action: { player.next() }) {
                                Image(systemName: "forward.fill")
                                    .font(.title)
                            }
                        }
                        .foregroundStyle(.white)

                        // 进度
                        VStack(spacing: CTSpacing.xs) {
                            ProgressSlider(
                                value: Binding(
                                    get: { player.currentTime },
                                    set: { player.seek(to: $0) }
                                ),
                                maximum: max(player.duration, 1),
                                buffered: player.bufferedTime
                            )
                            .frame(height: 4)

                            HStack {
                                Text(formatTime(player.currentTime))
                                Spacer()
                                Text(formatTime(player.duration))
                            }
                            .font(CTTypography.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        }
                        .frame(width: min(geometry.size.width * 0.35, 400))

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
        .onAppear {
            loadLyrics()
        }
        .onDisappear {
            lyricsTask?.cancel()
            lyricsTask = nil
        }
        .onChange(of: player.currentSong) { _, _ in
            loadLyrics()
        }
        // 0.1s 轮询歌词行高亮（订阅制，视图销毁自动取消，不会泄漏）
        .onReceive(lyricTimer) { _ in
            let index = LRCParser.currentLineIndex(in: lyrics, at: player.currentTime, offset: lyricOffset)
            if index != currentLineIndex {
                currentLineIndex = index
            }
        }
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

    /// 按歌曲来源选择歌词 Provider（本地/演示歌曲不应打到网易云接口）
    private static func fetchLyrics(for song: Song) async throws -> LyricResult {
        switch song.source {
        case .demo:
            return try await DemoProvider().fetchLyrics(songID: song.id)
        case .local:
            return try await LocalProvider.shared.fetchLyrics(songID: song.id)
        case .netease:
            return try await NeteaseProvider.shared.fetchLyrics(songID: song.id)
        }
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

struct LyricLineView: View {
    let line: LyricLine
    let isCurrent: Bool
    let showTranslation: Bool
    let showRomanization: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: CTSpacing.xs) {
            Text(line.text)
                .font(isCurrent ? .system(size: 20, weight: .semibold) : .system(size: 16))
                .foregroundStyle(isCurrent ? .white : .white.opacity(0.5))

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
}
