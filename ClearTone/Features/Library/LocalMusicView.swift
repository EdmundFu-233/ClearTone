import SwiftUI
import AppKit

/// 本地音乐页：扫描、导入、搜索、Finder 拖入
/// （原在 `App/MainWindow.swift`，按 P2-11 拆出）

struct LocalMusicView: View {
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme
    @State private var localSongs: [Song] = []
    @State private var isImporting = false
    @State private var importError: String?
    /// 本地曲库内的筛选词。导入几千首之后没有搜索基本没法用。
    @State private var searchText = ""

    private let localProvider = LocalProvider.shared

    /// 搜索结果。匹配歌名、艺人、专辑，大小写不敏感。
    /// 空关键词时返回全部，避免每次都拷一遍大数组。
    private var filteredSongs: [Song] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return localSongs }
        return localSongs.filter { song in
            song.title.localizedCaseInsensitiveContains(keyword)
                || song.artistNames.localizedCaseInsensitiveContains(keyword)
                || (song.album?.name.localizedCaseInsensitiveContains(keyword) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.Sidebar.local)
                    .font(CTTypography.pageTitle)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                Spacer()
                Button("导入文件") { importFiles() }
                    .buttonStyle(.bordered)
                Button("导入文件夹") { importFolder() }
                    .buttonStyle(.bordered)
            }
            .padding(CTSpacing.lg)

            // 搜索。只在已有曲目时出现 —— 空曲库上放搜索框是噪音。
            if !localSongs.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("在本地音乐中搜索", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Text("\(filteredSongs.count) / \(localSongs.count)")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            .monospacedDigit()
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索")
                    }
                }
                .padding(CTSpacing.sm)
                .background(CTColors.panel(for: colorScheme), in: RoundedRectangle(cornerRadius: CTRadius.small))
                .padding(.horizontal, CTSpacing.lg)
                .padding(.bottom, CTSpacing.sm)
            }

            if isImporting {
                ProgressView("导入中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = importError {
                ErrorView(message: error, retryAction: { importError = nil })
            } else if localSongs.isEmpty {
                EmptyStateView(icon: "folder", title: "本地音乐", message: "导入音频文件或文件夹开始播放")
            } else if filteredSongs.isEmpty {
                // 有曲库但搜索无结果：与「没有曲库」要区分开
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "没有匹配的音乐",
                    message: "换个关键词试试"
                )
            } else {
                List(filteredSongs) { song in
                    SongRowView(song: song, onPlay: {
                        player.play(songs: filteredSongs, startAt: filteredSongs.firstIndex(of: song) ?? 0)
                    })
                }
            }
        }
        .background(CTColors.background(for: colorScheme))
        // 启动时恢复上次导入的本地曲库
        .task { localSongs = await localProvider.restoreLibrary() }
        // 从 Finder 直接拖音频文件/文件夹进来即可导入
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        }
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        let audioFiles = Self.audioFilesIn(urls)
        guard !audioFiles.isEmpty else {
            importError = "拖入的内容里没有可识别的音频文件"
            return false
        }
        Task {
            isImporting = true
            defer { isImporting = false }
            do {
                if audioFiles.contains(where: { $0.hasDirectoryPath }) {
                    for url in audioFiles where url.hasDirectoryPath {
                        _ = try await localProvider.scanDirectory(url)
                    }
                } else {
                    _ = try await localProvider.importFiles(audioFiles)
                }
                localSongs = await localProvider.allSongs()
            } catch {
                importError = error.ctUserMessage
            }
        }
        return true
    }

    /// 从拖入的 URL 里挑出音频文件与文件夹。
    /// 混进来的非音频项直接丢掉 —— 否则 `importFiles` 会把它们当音频处理。
    private static func audioFilesIn(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            if url.hasDirectoryPath { return true }
            let ext = url.pathExtension.lowercased()
            return ["mp3", "m4a", "aac", "wav", "flac", "aiff", "alac", "caf", "ogg", "opus", "m4b"]
                .contains(ext)
        }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.begin { response in
            guard response == .OK else { return }
            Task {
                isImporting = true
                do {
                    _ = try await localProvider.importFiles(panel.urls)
                    localSongs = await localProvider.allSongs()
                } catch {
                    importError = error.ctUserMessage
                }
                isImporting = false
            }
        }
    }

    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                isImporting = true
                do {
                    _ = try await localProvider.scanDirectory(url)
                    localSongs = await localProvider.allSongs()
                } catch {
                    importError = error.ctUserMessage
                }
                isImporting = false
            }
        }
    }
}
