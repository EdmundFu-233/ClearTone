import SwiftUI
import MediaPlayer

struct IOSNowPlayingView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var time: Double = 0
    @State private var dragging = false
    /// 歌词状态机在 Core 里（`LyricsSession`）—— 与 macOS 的正在播放页共用一份，
    /// 切歌先清空、迟到响应丢弃、取消后复位 loading 这些边界才有断言。
    @StateObject private var lyrics = LyricsSession.neteaseOnly()
    @State private var lyricRefreshID = UUID()
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var showLogin = false
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 24) {
                        if let song = player.currentSong {
                            if showLyrics { lyricPanel.frame(height: max(240, min(380, geometry.size.height * 0.42))) }
                            else {
                                IOSCover(url: song.coverURL, size: min(320, max(160, geometry.size.width - 80)), cornerRadius: 26)
                                    .shadow(color: .black.opacity(0.12), radius: 20, y: 10).padding(.vertical, 12)
                            }
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
                            progressControl
                            playbackControls
                            SystemVolumeView().frame(height: 32).accessibilityLabel("系统音量与 AirPlay")
                            HStack(spacing: 0) {
                                if song.source == .netease {
                                    Button { showLyrics.toggle() } label: {
                                        Label(showLyrics ? "封面" : "歌词", systemImage: showLyrics ? "square" : "text.quote")
                                    }.accessibilityValue(showLyrics ? "歌词已显示" : "封面已显示")
                                    Spacer(minLength: 8)
                                    NavigationLink { IOSCommentsView(song: song) } label: { Label("评论", systemImage: "bubble.left") }
                                    Spacer(minLength: 8)
                                }
                                Button { showQueue = true } label: { Label("队列", systemImage: "music.note.list") }
                            }.font(.subheadline.weight(.medium)).buttonStyle(.borderless).frame(minHeight: 48)
                            if player.sleepTimerRemaining > 0 {
                                Label("\(Int(ceil(player.sleepTimerRemaining / 60))) 分钟后暂停", systemImage: "moon.zzz").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            ContentUnavailableView("还没有正在播放的歌曲", systemImage: "music.note", description: Text("到发现或资料库，选一首喜欢的音乐"))
                        }
                    }.padding(.horizontal, 28).padding(.vertical, 16).padding(.bottom, 24).frame(maxWidth: 520).frame(maxWidth: .infinity)
                }.background(IOSTheme.background)
            }
            .navigationTitle("正在播放").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("收起播放器")
                }
                ToolbarItem(placement: .primaryAction) { playbackMenu }
            }
        }
        .onAppear { time = player.currentTime }
        .onReceive(player.timePublisher) { value in if !dragging { time = min(max(0, value), max(1, player.duration)) } }
        .task(id: "\(player.currentSong?.id ?? "")-\(lyricRefreshID)") {
            time = player.currentTime
            dragging = false
            await lyrics.load(for: player.currentSong)
        }
        .sheet(isPresented: $showQueue) { IOSQueueView().presentationDragIndicator(.visible) }
        .sheet(isPresented: $showLogin) { IOSLoginView().presentationDragIndicator(.visible) }
    }

    private var progressControl: some View {
        VStack(spacing: 4) {
            Slider(value: $time, in: 0...max(1, player.duration), onEditingChanged: { editing in
                dragging = editing
                if !editing { player.commitSeek(to: time) }
            }).disabled(player.duration <= 0).accessibilityLabel("播放进度").accessibilityValue("\(Self.clock(time))，共 \(Self.clock(player.duration))")
            HStack { Text(Self.clock(time)); Spacer(); Text(Self.clock(player.duration)) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityHidden(true)
        }
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

    private var lyricPanel: some View {
        Group {
            if lyrics.isLoading { ProgressView("正在获取歌词…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let lyricError = lyrics.errorMessage { IOSFailure(message: lyricError) { lyricRefreshID = UUID() }.frame(maxHeight: .infinity) }
            else if lyrics.isPureMusic { ContentUnavailableView("纯音乐", systemImage: "music.note", description: Text("这首歌没有歌词")) }
            else if lyrics.lines.isEmpty { ContentUnavailableView("暂无歌词", systemImage: "text.quote", description: Text("让旋律自己说话")) }
            else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(lyrics.lines) { line in
                                Button { player.commitSeek(to: line.time) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(line.text).font(.title3.weight(activeLine?.id == line.id ? .bold : .medium))
                                        if let translation = line.translation { Text(translation).font(.subheadline) }
                                    }.foregroundStyle(activeLine?.id == line.id ? IOSTheme.accent : Color.secondary).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain).id(line.id).accessibilityHint("跳转到 \(Self.clock(line.time))")
                            }
                        }.padding(20)
                    }
                    .onAppear { if let id = activeLine?.id { proxy.scrollTo(id, anchor: .center) } }
                    .onChange(of: activeLine?.id) { _, id in
                        guard let id, !dragging else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }.background(IOSTheme.surface, in: RoundedRectangle(cornerRadius: 22))
    }
    private var activeLine: LyricLine? { lyrics.lines.last { $0.time <= time } }
    private var modeIcon: String {
        switch player.queue.mode {
        case .shuffle: "shuffle"
        case .loopOne: "repeat.1"
        case .loopAll: "repeat"
        case .sequential: "arrow.right"
        }
    }
    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
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
                    for id in ids { player.removeFromQueue(itemID: id) }
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
