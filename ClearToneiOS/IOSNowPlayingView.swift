import SwiftUI
import MediaPlayer

struct IOSNowPlayingView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var lyrics = LyricsSession.neteaseOnly()
    @State private var lyricRefreshID = UUID()
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var showLogin = false
    @State private var palette = ArtworkPalette.fallback

    private var songKey: String { "\(player.currentSong?.source.rawValue ?? ""):\(player.currentSong?.id ?? "")" }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let wide = geometry.size.width >= 680 && geometry.size.width > geometry.size.height && !dynamicTypeSize.isAccessibilitySize
                let coverLimit: CGFloat = geometry.size.width >= 680 ? 400 : 320
                let coverSize = wide ? min(coverLimit, max(180, geometry.size.height - 96)) : min(coverLimit, max(160, min(geometry.size.width - 64, geometry.size.height - 440)))
                let layout = wide ? AnyLayout(HStackLayout(alignment: .center, spacing: 32)) : AnyLayout(VStackLayout(spacing: 24))
                ScrollView {
                    if let song = player.currentSong {
                        layout {
                            artworkPanel(song: song, size: coverSize)
                            VStack(spacing: wide ? 12 : 20) {
                                songDetails(song)
                                IOSPlaybackProgress()
                                playbackControls
                                SystemVolumeView().frame(height: 32).accessibilityLabel("系统音量与 AirPlay")
                                secondaryActions(song)
                                if player.sleepTimerRemaining > 0 {
                                    Label("\(Int(ceil(player.sleepTimerRemaining / 60))) 分钟后暂停", systemImage: "moon.zzz")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: 440)
                        }
                        .padding(.horizontal, wide ? 32 : 24)
                        .padding(.top, wide ? 12 : 20)
                        .padding(.bottom, wide ? 12 : 36)
                        .frame(maxWidth: wide ? 1000 : 520)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    } else {
                        ContentUnavailableView("还没有正在播放的歌曲", systemImage: "music.note", description: Text("到发现或资料库，选一首喜欢的音乐"))
                            .frame(minHeight: geometry.size.height)
                    }
                }
                .background {
                    IOSTheme.background.overlay {
                        LinearGradient(colors: palette.swiftUIColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                            .opacity(0.10).ignoresSafeArea()
                    }
                }
            }
            .navigationTitle("正在播放").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                        .accessibilityLabel("收起播放器")
                }
                ToolbarItem(placement: .primaryAction) { playbackMenu }
            }
        }
        .onChange(of: songKey) { _, _ in lyrics.reset() }
        .task(id: "\(songKey):\(lyricRefreshID)") {
            await lyrics.load(for: player.currentSong)
        }
        .task(id: player.currentSong?.coverURL) {
            let image = await CoverLoader.shared.load(url: player.currentSong?.coverURL, pointSize: 64)
            guard !Task.isCancelled else { return }
            let next = if let image = image?.cgImage { await ArtworkPalette.extract(from: image) } else { ArtworkPalette.fallback }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) { palette = next }
        }
        .sheet(isPresented: $showQueue) { IOSQueueView().presentationDragIndicator(.visible) }
        .sheet(isPresented: $showLogin) { IOSLoginView().presentationDragIndicator(.visible) }
    }

    private func artworkPanel(song: Song, size: CGFloat) -> some View {
        ZStack {
            if showLyrics {
                IOSLyricsPane(lyrics: lyrics, retry: { lyricRefreshID = UUID() }).transition(.opacity)
            } else {
                IOSCover(url: song.coverURL, size: size, cornerRadius: 24)
                    .overlay { RoundedRectangle(cornerRadius: 24).stroke(.primary.opacity(0.06), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.16), radius: 20, y: 12)
                    .scaleEffect(player.playbackState.isPlayIntentActive || reduceMotion ? 1 : 0.95)
                    .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: player.playbackState.isPlayIntentActive)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size + 24)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showLyrics)
    }

    private func songDetails(_ song: Song) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(song.title).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    Text(song.artistNames).font(.body).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if song.source == .netease {
                    Button {
                        if appState.canPerformWrite { Task { _ = await appState.toggleLike(song) } }
                        else { showLogin = true }
                    } label: {
                        Image(systemName: appState.isLiked(song.id) ? "heart.fill" : "heart").font(.title2).foregroundStyle(appState.isLiked(song.id) ? Color.pink : Color.primary).frame(width: 48, height: 48)
                    }
                    .disabled(appState.isLikeWriteCoolingDown)
                    .accessibilityLabel(appState.isLiked(song.id) ? "取消喜欢" : "喜欢")
                }
            }
            if appState.isLikeWriteCoolingDown {
                IOSWriteCooldownNotice(
                    remaining: appState.likeCooldownRemaining,
                    message: appState.likesWriteError
                )
            }
            if let quality = player.actualQuality {
                Text([quality.level == .unknown ? nil : quality.level.rawValue, quality.codec, quality.bitrate.map { "\($0) kbps" }, player.isCurrentFromCache ? "本地缓存" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .failed(_, let reason) = player.playbackState {
                VStack(spacing: 10) {
                    Text(reason).font(.subheadline).foregroundStyle(.secondary)
                    Button("重新播放", systemImage: "arrow.clockwise") { player.playCurrent() }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity).iosCard()
            } else if player.playbackState.isLoading || player.playbackState.isBuffering {
                ProgressView(player.playbackState.isLoading ? "正在加载歌曲…" : "正在缓冲…").font(.caption)
            }
        }
    }

    private func secondaryActions(_ song: Song) -> some View {
        HStack(spacing: 12) {
            if song.source == .netease {
                Button { showLyrics.toggle() } label: {
                    Label(showLyrics ? "封面" : "歌词", systemImage: showLyrics ? "square" : "text.quote")
                }.accessibilityValue(showLyrics ? "歌词已显示" : "封面已显示")
                Spacer(minLength: 0)
                NavigationLink { IOSCommentsView(song: song) } label: { Label("评论", systemImage: "bubble.left") }
                Spacer(minLength: 0)
            }
            Button { showQueue = true } label: { Label("队列", systemImage: "music.note.list") }
        }.font(.subheadline.weight(.medium)).buttonStyle(.borderless).frame(minHeight: 44)
    }

    private var playbackControls: some View {
        HStack(spacing: 0) {
            Button { player.cyclePlayMode() } label: { Image(systemName: modeIcon).frame(width: 44, height: 44) }.accessibilityLabel("播放模式，\(player.queue.mode.rawValue)").accessibilityHint("点按切换播放模式")
            Spacer(minLength: 0)
            Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel("上一首")
            Spacer(minLength: 0)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.playbackState.isPlayIntentActive ? "pause.fill" : "play.fill").font(.system(size: 28, weight: .semibold)).frame(width: 72, height: 72).foregroundStyle(.white).background(IOSTheme.accent, in: Circle())
            }.accessibilityLabel(player.playbackState.isPlayIntentActive ? "暂停" : "播放")
            Spacer(minLength: 0)
            Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel("下一首")
            Spacer(minLength: 0)
            Button { showQueue = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel("播放队列，\(player.queue.items.count) 首")
        }.foregroundStyle(.primary)
    }

    private var playbackMenu: some View {
        Menu {
            Menu("播放速度 · \(PlayerController.rateLabel(player.playbackRate))") {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button { player.setPlaybackRate(Float(rate)) } label: {
                        if player.playbackRate == Float(rate) { Label(PlayerController.rateLabel(Float(rate)), systemImage: "checkmark") }
                        else { Text(PlayerController.rateLabel(Float(rate))) }
                    }
                }
            }
            Menu("睡眠定时") {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in Button("\(minutes) 分钟") { player.setSleepTimer(minutes: Double(minutes)) } }
                Button("关闭定时器") { player.setSleepTimer(minutes: 0) }
            }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("播放速度与睡眠定时")
    }

    private var modeIcon: String {
        switch player.queue.mode {
        case .shuffle: "shuffle"
        case .loopOne: "repeat.1"
        case .loopAll: "repeat"
        case .sequential: "arrow.right"
        }
    }
}

private struct IOSPlaybackProgress: View {
    @EnvironmentObject private var player: PlayerController
    @State private var time: Double = 0
    @State private var dragging = false
    var body: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { PlaybackPresentation.position(time, duration: player.duration) }, set: { time = $0 }),
                   in: 0...PlaybackPresentation.seekLimit(player.duration), onEditingChanged: { editing in
                dragging = editing
                if !editing { player.commitSeek(to: time) }
            })
            .disabled(!player.duration.isFinite || player.duration <= 0)
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(PlaybackPresentation.timeLabel(time))，共 \(PlaybackPresentation.timeLabel(player.duration))")
            HStack {
                Text(PlaybackPresentation.timeLabel(time))
                Spacer()
                Text(PlaybackPresentation.timeLabel(player.duration))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .onAppear { time = player.currentTime }
        .onReceive(player.timePublisher) { if !dragging { time = $0 } }
        .onChange(of: player.currentSong) { _, _ in dragging = false; time = player.currentTime }
    }
}

private struct IOSLyricsPane: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var lyrics: LyricsSession
    let retry: () -> Void
    @State private var time: Double = 0
    @State private var userScrolling = false
    private var activeID: UUID? {
        guard let index = LRCParser.currentLineIndex(in: lyrics.lines, at: time, offset: settings.settings.lyricOffset) else { return nil }
        return lyrics.lines[index].id
    }
    var body: some View {
        let currentID = activeID
        Group {
            if lyrics.isLoading {
                ProgressView("正在获取歌词…")
            } else if let error = lyrics.errorMessage {
                IOSFailure(message: error, retry: retry)
            } else if lyrics.lines.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: lyrics.isPureMusic ? "waveform" : "text.quote").font(.largeTitle)
                    Text(lyrics.isPureMusic ? "纯音乐" : "暂无歌词").font(.headline)
                }.foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(lyrics.lines) { line in
                                Button { player.commitSeek(to: max(0, line.time - settings.settings.lyricOffset)) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        CTTimedLyricText(line: line, time: time + settings.settings.lyricOffset, isCurrent: currentID == line.id, active: IOSTheme.accent)
                                            .font(.title3.weight(.semibold))
                                        if let translation = line.translation, !translation.isEmpty {
                                            Text(translation).font(.subheadline).foregroundStyle(.secondary)
                                        }
                                    }
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).id(line.id)
                                .accessibilityLabel(line.text)
                                .accessibilityValue(currentID == line.id ? "当前歌词" : "")
                                .accessibilityHint("跳转到 \(PlaybackPresentation.timeLabel(max(0, line.time - settings.settings.lyricOffset)))")
                            }
                        }.padding(.horizontal, 20).padding(.vertical, 64)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { if let currentID { proxy.scrollTo(currentID, anchor: .center) } }
                    .onChange(of: currentID) { _, id in
                        guard let id, !userScrolling else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .simultaneousGesture(DragGesture().onChanged { _ in userScrolling = true })
                    .overlay(alignment: .bottom) {
                        if userScrolling {
                            Button {
                                userScrolling = false
                                if let id = currentID ?? lyrics.lines.first?.id {
                                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                                }
                            } label: { Label("回到当前", systemImage: "arrow.uturn.backward").font(.caption.weight(.semibold)) }
                                .buttonStyle(.borderedProminent).padding(12)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IOSTheme.surface, in: RoundedRectangle(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .onAppear { time = player.currentTime }
        .onReceive(player.timePublisher) { time = $0 }
        .onChange(of: player.currentSong) { _, _ in time = player.currentTime; userScrolling = false }
    }
}

struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { MPVolumeView(frame: .zero) }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct IOSQueueView: View {
    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    @State private var clearing = false
    var body: some View {
        NavigationStack {
            List {
                if player.queue.items.isEmpty { ContentUnavailableView("队列为空", systemImage: "music.note.list") }
                ForEach(player.queue.items) { item in
                    Button {
                        if player.queue.jumpTo(itemID: item.id) { player.playCurrent() }
                    } label: {
                        HStack {
                            IOSCover(url: item.song.coverURL)
                            VStack(alignment: .leading) { Text(item.song.title); Text(item.song.artistNames).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if player.queue.currentItem?.id == item.id { Image(systemName: "waveform") }
                        }
                    }.buttonStyle(.plain)
                }.onDelete { indices in
                    let ids = indices.map { player.queue.items[$0].id }
                    // 先删非当前项，最后才删当前项。否则删当前项会立刻开始播放
                    // 一个也在本批次里的「下一首」，随后它又被删掉 ——
                    // 听感上是一串快速的乱切。
                    let currentID = player.queue.currentItem?.id
                    for id in ids where id != currentID { player.removeFromQueue(itemID: id) }
                    if let currentID, ids.contains(currentID) { player.removeFromQueue(itemID: currentID) }
                }.onMove { source, destination in player.moveQueueItems(fromOffsets: source, toOffset: destination) }
            }
            .navigationTitle("播放队列 · \(player.queue.items.count)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .bottomBar) { Button("清空队列", role: .destructive) { clearing = true }.disabled(player.queue.items.isEmpty) }
            }
            .confirmationDialog("清空队列并停止播放？", isPresented: $clearing, titleVisibility: .visible) {
                Button("清空", role: .destructive) { player.clearQueue() }
            }
        }
    }
}
