import SwiftUI

/// 私人 FM。
///
/// 网易云的「私人 FM」是一个 endless 流：每次给 3 首，播完再要 3 首。
/// 这里用 `player.play(songs:startAt:)` 播完当前批次后自动续拉，
/// 并把批次插到队列里，从而不打断已有的队列内容。
struct PersonalFMView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    @State private var songs: [Song] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasMore = true
    @StateObject private var commentsStore = CommentsStore()

    private let provider = NeteaseProvider.shared
    @State private var loadToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CTPageHeader(
                    title: "私人 FM",
                    subtitle: "根据你的口味生成 endless 流。",
                    icon: "waveform.badge.magnifyingglass"
                )
                Spacer()
                HStack(spacing: CTSpacing.md) {
                    if !songs.isEmpty {
                        Button {
                            player.play(songs: songs, startAt: 0)
                        } label: {
                            Label("从头播放", systemImage: "play.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                    Button {
                        Task { await loadMore(reset: true) }
                    } label: {
                        Label("换一批", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!appState.canPerformWrite || isLoading)
                }
            }
            .padding(CTSpacing.xl)

            if !appState.canPerformWrite {
                LoginRequiredView(feature: "私人 FM")
            } else if isLoading && songs.isEmpty {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ErrorView(message: error) { Task { await loadMore(reset: true) } }
            } else if songs.isEmpty {
                EmptyStateView(icon: "waveform", title: "私人 FM", message: "点「换一批」获取推荐")
            } else {
                List {
                    ForEach(songs) { song in
                        SongRowView(song: song) {
                            player.play(songs: songs, startAt: songs.firstIndex(of: song) ?? 0)
                        }
                    }
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                    } else if hasMore {
                        Button {
                            Task { await loadMore(reset: false) }
                        } label: {
                            Label("再来 3 首", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(CTColors.background(for: colorScheme))
        .task { await loadMore(reset: true) }
        .onChange(of: appState.dataContextKey) { _, _ in
            Task { await loadMore(reset: true) }
        }
    }

    private func loadMore(reset: Bool) async {
        let token = UUID()
        loadToken = token
        isLoading = true
        if reset { errorMessage = nil }
        do {
            let batch = try await provider.fetchPersonalFM()
            guard loadToken == token, !Task.isCancelled else { return }
            if reset {
                songs = batch
            } else {
                // 官方 FM 同一首可能在不同批次里出现，按 id 去重
                let existing = Set(songs.map(\.id))
                songs.append(contentsOf: batch.filter { !existing.contains($0.id) })
            }
            // 少于 3 首说明推荐池见底了
            hasMore = batch.count >= 3
        } catch {
            guard loadToken == token else { return }
            if reset {
                errorMessage = error.ctUserMessage
                songs = []
            } else {
                CTLog.general.error("加载私人 FM 失败: \(CTLog.sanitize(error.localizedDescription))")
            }
            hasMore = false
        }
        guard loadToken == token else { return }
        isLoading = false
    }
}
