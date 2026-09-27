import SwiftUI

/// 歌单详情页
/// （原在 `App/MainWindow.swift`，按 P2-11 拆出）

struct PlaylistDetailView: View {
    let playlistID: String
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    @State private var detail: PlaylistDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// 加载代次：切换歌单时 .task(id:) 只保证取消旧 Task，但旧 load() 可能已跨过 await 恢复，
    /// 继续写共享的 detail，会把上一个歌单的条目覆盖到当前歌单上。用代次令牌做提交前校验。
    @State private var loadToken = UUID()
    @State private var isSubscribed: Bool?
    @State private var renameTarget: Playlist?
    @State private var deleteTarget: Playlist?
    @State private var pendingRemoval: [String] = []
    @State private var showRemoveConfirm = false

    private let provider = NeteaseProvider.shared

    /// 是不是自己创建的歌单（决定能否改名/删除/增删曲目）
    private var isOwned: Bool {
        appState.userPlaylists.contains { $0.id == playlistID }
    }

    private var tracks: [Song] { detail?.tracks ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ErrorView(message: error, retryAction: { Task { await load() } })
            } else if let detail {
                // 歌单头部
                HStack(alignment: .top, spacing: CTSpacing.lg) {
                    CoverImage(url: detail.playlist.coverURL, size: 160) {
                        RoundedRectangle(cornerRadius: CTRadius.medium)
                            .fill(CTColors.overlay(for: colorScheme))
                            .overlay(Image(systemName: "music.note.list").foregroundStyle(.secondary))
                    }
                    .frame(width: 160, height: 160)
                    .clipped()
                    .cornerRadius(CTRadius.medium)

                    VStack(alignment: .leading, spacing: CTSpacing.sm) {
                        Text(detail.playlist.name)
                            .font(CTTypography.pageTitle)
                            .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                        if let creator = detail.playlist.creatorName {
                            Text("创建者：\(creator)")
                                .font(CTTypography.caption)
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        }
                        HStack(spacing: CTSpacing.sm) {
                            Text("\(detail.totalTrackCount) 首歌曲")
                                .font(CTTypography.caption)
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            if tracks.count < detail.totalTrackCount {
                                // 分页仍在并发补齐，先给出进度避免用户以为加载卡死
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                                Text("已加载 \(tracks.count) 首")
                                    .font(CTTypography.caption)
                                    .foregroundStyle(CTColors.textSecondary(for: colorScheme).opacity(0.7))
                            }
                        }

                        HStack(spacing: CTSpacing.md) {
                            Button {
                                player.play(songs: tracks, startAt: 0)
                            } label: {
                                Label("播放全部", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(tracks.isEmpty)

                            PlaylistActionsMenu(
                                playlist: detail.playlist,
                                isOwned: isOwned,
                                isSubscribed: isSubscribed ?? false,
                                onSubscribe: { newValue in
                                    await subscribePlaylist(newValue)
                                },
                                onRename: isOwned ? { renameTarget = detail.playlist } : nil,
                                onDelete: isOwned ? { deleteTarget = detail.playlist } : nil
                            )
                        }
                    }
                    Spacer()
                }
                .padding(CTSpacing.xl)

                List(tracks) { song in
                    SongRowView(song: song, onPlay: {
                        player.play(songs: tracks, startAt: tracks.firstIndex(of: song) ?? 0)
                    })
                    .contextMenu {
                        if isOwned && song.source == .netease {
                            Button("从这个歌单移除", role: .destructive) {
                                pendingRemoval = [song.id]
                                showRemoveConfirm = true
                            }
                        }
                    }
                }
            } else {
                EmptyStateView(icon: "music.note.list", title: "歌单", message: "歌单不存在")
            }
        }
        .background(CTColors.background(for: colorScheme))
        .sheet(item: $renameTarget) { playlist in
            PlaylistNameSheet(mode: .rename(playlist)) { name in
                await appState.renamePlaylist(playlist, to: name)
            } onCancel: {
                renameTarget = nil
            }
            .environmentObject(appState)
        }
        .sheet(item: $deleteTarget) { playlist in
            ConfirmDeletePlaylistSheet(playlist: playlist) {
                await appState.deletePlaylist(playlist)
            } onCancel: {
                deleteTarget = nil
            }
            .environmentObject(appState)
        }
        // 原先这里还有一个 `showCreatePlaylist` 的「新建歌单」sheet，
        // 但没有任何写入方 —— 纯死代码，已删。本页加歌走歌曲行的
        // 「添加到歌单…」，那个 sheet 里本来就带「新建歌单」入口。
        .alert("从歌单移除", isPresented: $showRemoveConfirm) {
            Button("取消", role: .cancel) { pendingRemoval = [] }
            Button("移除", role: .destructive) {
                let ids = pendingRemoval
                pendingRemoval = []
                Task { await removeSongs(ids) }
            }
        } message: {
            Text("确定要从这个歌单移除选中的 \(pendingRemoval.count) 首歌曲吗？")
        }
        .alert("操作失败", isPresented: Binding(
            get: { appState.lastWriteError != nil },
            set: { if !$0 { appState.clearWriteError() } }
        )) {
            Button("好") { appState.clearWriteError() }
        } message: {
            Text(appState.lastWriteError ?? "")
        }
        // 歌单 ID 或登录态变化时重新加载
        .task(id: "\(playlistID)-\(appState.dataContextKey)") { await load() }
    }

    // MARK: - 写操作

    private func subscribePlaylist(_ subscribe: Bool) async {
        do {
            try await provider.subscribePlaylist(id: playlistID, subscribe: subscribe)
            isSubscribed = subscribe
        } catch {
            appState.clearWriteError()
            errorMessage = error.ctUserMessage
        }
    }

    private func removeSongs(_ ids: [String]) async {
        guard let playlist = detail?.playlist else { return }
        let token = loadToken
        let ok = await appState.modifyPlaylist(playlist, songIDs: ids, add: false)
        // 必须比对**捕获的** token：原来写的是 `loadToken == loadToken`，恒真。
        // 后果是在 A 歌单移除歌曲的请求在途时点开 B 歌单，
        // `removeAll` 会作用到 B 的曲目上，B 里同名的那一行无中生有地消失。
        guard ok, loadToken == token else { return }
        // 本地先移除，避免用户以为没生效；下次进入会从服务端重新校准
        detail?.tracks.removeAll { ids.contains($0.id) }
    }

    private func load() async {
        guard !playlistID.isEmpty else { return }
        // 领取新代次并立即作废旧代次的所有在途写入
        let token = UUID()
        loadToken = token
        isLoading = true
        errorMessage = nil
        // 切歌单时先清空上一个歌单的内容，避免新旧混排
        detail = nil
        do {
            if let cached = await provider.cachedPlaylistTracks(id: playlistID) {
                var loaded = try await provider.fetchPlaylistDetail(id: playlistID)
                guard loadToken == token, !Task.isCancelled else { return }
                loaded.tracks = cached
                detail = loaded
                isLoading = false
                return
            }

            // 1. 先只取详情并立即渲染（标题/封面/首屏曲目），不再等全部分页结束
            let loaded = try await provider.fetchPlaylistDetail(id: playlistID)
            guard loadToken == token, !Task.isCancelled else { return }
            detail = loaded
            isLoading = false

            // 2. 其余分页并发拉取，边到边追加
            guard loaded.totalTrackCount > loaded.tracks.count,
                  loaded.totalTrackCount > 0 else { return }
            // 按 id 去重：`/playlist/detail` 已经带了前若干首，而
            // `streamPlaylistTracks` 是从**第 1 页**开始发的，两边重叠。
            // 直接 append 会把同一批歌追加两遍 —— 2808 首的歌单能渲染出
            // 3808 行，「播放全部」也会把重复曲目塞进队列。
            var seenIDs = Set(loaded.tracks.map(\.id))
            var accumulated = loaded.tracks
            for try await batch in await provider.streamPlaylistTracks(
                id: playlistID,
                totalCount: loaded.totalTrackCount
            ) {
                // 每个批次提交前都要校验代次：旧歌单的迟到批次必须丢弃
                guard loadToken == token, !Task.isCancelled else { return }
                let fresh = batch.filter { seenIDs.insert($0.id).inserted }
                guard !fresh.isEmpty else { continue }
                accumulated.append(contentsOf: fresh)
                guard var current = detail else { return }
                current.tracks = accumulated
                detail = current
            }
        } catch {
            guard loadToken == token else { return }
            errorMessage = error.ctUserMessage
        }
        guard loadToken == token else { return }
        isLoading = false
    }
}
