import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var audioCache = AudioCacheManager.shared
    @StateObject private var lyrics = LyricsSession(resolve: { song in
        switch song.source {
        case .local: LocalProvider.shared
        case .netease: NeteaseProvider.shared
        }
    })
    @State private var refreshID = UUID()
    @State private var palette = ArtworkPalette.fallback
    @State private var showTranslation = true
    @State private var showRomanization = false

    private var songKey: String { "\(player.currentSong?.source.rawValue ?? ""):\(player.currentSong?.id ?? "")" }

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = min(420, geometry.size.width * 0.43)
            let coverSize = max(160, min(columnWidth - 56, geometry.size.height - 400))
            ZStack {
                background
                HStack(spacing: 24) {
                    ScrollView {
                        VStack(spacing: 24) {
                            artwork(size: coverSize)
                            songInformation
                            playbackControls
                            MacPlaybackProgress()
                            playbackStatus
                        }
                        .frame(maxWidth: 360)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: max(0, geometry.size.height - 72))
                    }
                    .scrollIndicators(.hidden)
                    .frame(width: columnWidth)

                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 10) {
                            Text("歌词").font(.headline)
                            Spacer(minLength: 8)
                            Toggle("翻译", isOn: $showTranslation)
                            Toggle("音译", isOn: $showRomanization)
                            LyricOffsetControl()
                        }
                        .toggleStyle(.button)
                        .font(.caption)
                        .padding(.horizontal, 20)

                        MacLyricsPane(lyrics: lyrics, showTranslation: showTranslation,
                                      showRomanization: showRomanization,
                                      retry: { refreshID = UUID() })
                    }
                    .padding(.vertical, 24)
                    .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 24))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.08), lineWidth: 1)
                    }
                }
                .padding(.top, 48)
                .padding(.bottom, 24)
                .padding(.trailing, 24)
            }
        }
        .frame(minWidth: 800, idealWidth: 1000, minHeight: 560, idealHeight: 680)
        .colorScheme(.dark)
        .foregroundStyle(.white)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("收起正在播放")
                .help("收起正在播放")
                Text("正在播放").font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.75))
            }.padding(16)
        }
        .onChange(of: songKey) { _, _ in lyrics.reset() }
        .task(id: "\(songKey):\(refreshID)") {
            await lyrics.load(for: player.currentSong)
        }
        .task(id: player.currentSong?.coverURL) {
            guard let url = player.currentSong?.coverURL else {
                palette = .fallback
                return
            }
            let image = await CoverLoader.shared.load(url: url, pointSize: 64)
            guard !Task.isCancelled else { return }
            var rect = CGRect.zero
            let cgImage = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            let next = if let cgImage { await ArtworkPalette.extract(from: cgImage) } else { ArtworkPalette.fallback }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) { palette = next }
        }
    }

    private var background: some View {
        ZStack {
            CTColors.immersiveBase
            LinearGradient(colors: palette.swiftUIColors, startPoint: .topLeading, endPoint: .bottomTrailing)
            if !reduceMotion && settings.settings.performanceMode != .static_ {
                MetalBackgroundView(
                    colors: .constant(palette.swiftUIColors), spectrum: .constant([]),
                    isAnimating: .constant(scenePhase == .active),
                    showSpectrum: .constant(false),
                    renderScale: settings.settings.performanceMode == .saver ? 0.3 :
                        (settings.settings.performanceMode == .auto ? 0.5 : 0.6)
                )
            }
        }.ignoresSafeArea()
    }

    private func artwork(size: CGFloat) -> some View {
        CoverImage(url: player.currentSong?.coverURL, size: size, contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12), lineWidth: 1) }
            .shadow(color: .black.opacity(0.28), radius: 20, y: 12)
            .scaleEffect(player.playbackState.isPlayIntentActive || reduceMotion ? 1 : 0.95)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: player.playbackState.isPlayIntentActive)
            .accessibilityHidden(true)
    }

    private var songInformation: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                Text(player.currentSong?.title ?? "选择一首音乐")
                    .font(.system(size: 25, weight: .bold))
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if let song = player.currentSong, song.source == .netease {
                    Button { Task { await appState.toggleLike(song) } } label: {
                        Image(systemName: appState.isLiked(song.id) ? "heart.fill" : "heart")
                            .font(.title2)
                            .foregroundStyle(appState.isLiked(song.id) ? Color(hex: 0xFF9A9D) : .white)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .disabled(!appState.canPerformWrite || appState.isLikeWriteCoolingDown)
                    .accessibilityLabel(appState.isLiked(song.id) ? "取消收藏" : "收藏")
                    .help(appState.isLoggedIn ? "收藏到喜欢的音乐" : "登录后收藏歌曲")
                }
            }
            Text(player.currentSong?.artistNames ?? "让音乐陪你一会儿")
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
            if let info = player.playingSourceInfo, let song = player.currentSong {
                let label = Label(info.text, systemImage: info.isFromCache ? "internaldrive" : "waveform")
                    .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.08), in: Capsule())
                if song.source == .netease {
                    SongQualityMenu(songID: song.id, help: info.detail) { label }
                } else { label.help(info.detail) }
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 32) {
            Button { player.previous() } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 24)).frame(width: 44, height: 44)
            }.accessibilityLabel("上一首").help("上一首")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.playbackState.isPlayIntentActive ? "pause.fill" : "play.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(CTColors.immersiveBase)
                    .frame(width: 64, height: 64)
                    .background(.white, in: Circle())
            }
            .accessibilityLabel(player.playbackState.isPlayIntentActive ? "暂停" : "播放")
            .help(player.playbackState.isPlayIntentActive ? "暂停" : "播放")
            Button { player.next() } label: {
                Image(systemName: "forward.end.fill").font(.system(size: 24)).frame(width: 44, height: 44)
            }.accessibilityLabel("下一首").help("下一首")
        }
        .buttonStyle(PlaybackPressStyle())
        .disabled(player.currentSong == nil)
    }

    @ViewBuilder private var playbackStatus: some View {
        if case .failed(_, let reason) = player.playbackState {
            VStack(spacing: 8) {
                Text(reason).font(.caption).multilineTextAlignment(.center)
                Button("重新播放", systemImage: "arrow.clockwise") { player.playCurrent() }
                    .buttonStyle(.bordered)
            }.foregroundStyle(.white.opacity(0.85))
        } else if player.playbackState.isLoading || player.playbackState.isBuffering {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(player.playbackState.isLoading ? "正在加载歌曲…" : "正在缓冲…").font(.caption)
            }.foregroundStyle(.white.opacity(0.75))
        }
    }
}

private struct PlaybackPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct MacPlaybackProgress: View {
    @EnvironmentObject private var player: PlayerController
    @State private var dragging = false
    var body: some View {
        PlaybackTimeObserver(player: player) { time in
            VStack(spacing: 9) {
                ProgressSlider(value: Binding(
                    get: { PlaybackPresentation.position(time, duration: player.duration) },
                    set: { dragging ? player.previewSeek(to: $0) : player.commitSeek(to: $0) }
                ), maximum: PlaybackPresentation.seekLimit(player.duration), buffered: player.bufferedTime,
                               onEditingChanged: { editing in
                    dragging = editing
                    if !editing { player.commitSeek(to: player.currentTime) }
                })
                .frame(height: 5)
                .disabled(!player.duration.isFinite || player.duration <= 0)
                HStack {
                    Text(PlaybackPresentation.timeLabel(time))
                    Spacer()
                    Text(PlaybackPresentation.timeLabel(player.duration))
                }.font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

private struct MacLyricsPane: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var lyrics: LyricsSession
    let showTranslation: Bool
    let showRomanization: Bool
    let retry: () -> Void
    @State private var time: TimeInterval = 0
    @State private var userScrolling = false

    var body: some View {
        Group {
            if lyrics.isLoading {
                ProgressView(L10n.Player.loadingLyrics)
            } else if let error = lyrics.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                    Text(error).font(.callout).multilineTextAlignment(.center)
                    Button(L10n.Common.retry, action: retry).buttonStyle(.bordered)
                }.padding(24)
            } else if lyrics.lines.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: lyrics.isPureMusic ? "waveform" : "text.quote").font(.system(size: 32))
                    Text(lyrics.isPureMusic ? L10n.Player.pureMusic : L10n.Player.noLyrics).font(.headline)
                }.foregroundStyle(.white.opacity(0.75))
            } else {
                LyricListView(lyrics: lyrics.lines,
                              currentIndex: LRCParser.currentLineIndex(in: lyrics.lines, at: time, offset: settings.settings.lyricOffset),
                              currentTime: time + settings.settings.lyricOffset,
                              showTranslation: showTranslation, showRomanization: showRomanization,
                              userScrolling: $userScrolling,
                              onSeek: { player.commitSeek(to: max(0, $0 - settings.settings.lyricOffset)) })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { time = player.currentTime }
        .onChange(of: player.currentSong) { _, _ in time = player.currentTime; userScrolling = false }
        .onReceive(player.timePublisher) { value in
            guard scenePhase == .active else { return }
            time = value
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { time = player.currentTime }
        }
    }
}

struct LyricListView: View {
    let lyrics: [LyricLine]
    let currentIndex: Int?
    let currentTime: TimeInterval
    let showTranslation: Bool
    let showRomanization: Bool
    @Binding var userScrolling: Bool
    let onSeek: (TimeInterval) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(lyrics.indices, id: \.self) { index in
                            LyricLineView(line: lyrics[index], isCurrent: index == currentIndex,
                                          currentTime: index == currentIndex ? currentTime : 0,
                                          showTranslation: showTranslation, showRomanization: showRomanization,
                                          onTap: { onSeek(lyrics[index].time) })
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, max(24, geometry.size.height * 0.35))
                }
                .scrollIndicators(.hidden)
                .background(LyricScrollActivity { userScrolling = true })
                .onAppear { if let currentIndex { proxy.scrollTo(currentIndex, anchor: .center) } }
                .onChange(of: currentIndex) { _, index in
                    guard !userScrolling, let index else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { proxy.scrollTo(index, anchor: .center) }
                }
                .onChange(of: userScrolling) { _, scrolling in
                    guard !scrolling else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(currentIndex ?? 0, anchor: .center) }
                }
                .simultaneousGesture(DragGesture().onChanged { _ in userScrolling = true })
                .overlay(alignment: .bottom) {
                    if userScrolling {
                        Button { userScrolling = false } label: {
                            Label(L10n.Player.backToCurrent, systemImage: "arrow.uturn.backward")
                                .font(.caption.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 10)
                                .background(CTColors.immersiveBase, in: Capsule())
                                .overlay { Capsule().stroke(.white.opacity(0.2), lineWidth: 1) }
                        }.buttonStyle(.plain).padding(.bottom, 12)
                    }
                }
            }
        }
    }
}

struct LyricLineView: View {
    let line: LyricLine
    let isCurrent: Bool
    let currentTime: TimeInterval
    let showTranslation: Bool
    let showRomanization: Bool
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                CTTimedLyricText(line: line, time: currentTime, isCurrent: isCurrent,
                                 active: .white, inactive: .white.opacity(0.65))
                    .font(.system(size: 23, weight: .semibold))
                if showTranslation, let translation = line.translation, !translation.isEmpty {
                    Text(translation).font(.system(size: 14)).foregroundStyle(.white.opacity(isCurrent ? 0.85 : 0.75))
                }
                if showRomanization, let romanization = line.romanization, !romanization.isEmpty {
                    Text(romanization).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(12)
            .background(.white.opacity(isCurrent ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line.text)
        .accessibilityValue(isCurrent ? "当前歌词" : "")
        .accessibilityHint("跳转到 \(PlaybackPresentation.timeLabel(line.time))")
        .help("点击跳转到 \(PlaybackPresentation.timeLabel(line.time))")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isCurrent)
    }
}
