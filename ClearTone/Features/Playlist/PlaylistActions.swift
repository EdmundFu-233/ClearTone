import SwiftUI

/// 新建 / 重命名歌单对话框。
struct PlaylistNameSheet: View {
    enum Mode {
        case create
        case rename(Playlist)

        var title: String {
            switch self {
            case .create: return "新建歌单"
            case .rename: return "重命名歌单"
            }
        }
    }

    let mode: Mode
    /// 完成后回调。create 成功时返回新歌单
    let onComplete: (String) async -> Bool
    /// 取消
    let onCancel: () -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var name: String = ""
    @State private var isPrivate = false
    @State private var isWorking = false
    @FocusState private var isNameFocused: Bool

    private let maxLength = 40

    var body: some View {
        VStack(alignment: .leading, spacing: CTSpacing.lg) {
            Text(mode.title)
                .font(CTTypography.sectionTitle)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))

            VStack(alignment: .leading, spacing: CTSpacing.xs) {
                TextField("歌单名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit { submit() }
                HStack {
                    Text("\(name.count)/\(maxLength)")
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    Spacer()
                }
            }

            if case .create = mode {
                Toggle("隐私歌单（不公开显示）", isOn: $isPrivate)
                    .toggleStyle(.switch)
            }

            if let error = appState.lastWriteError {
                Text(error)
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.accent(for: colorScheme))
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(mode.title, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
        }
        .padding(CTSpacing.xl)
        .frame(width: 380)
        .background(CTColors.panel(for: colorScheme))
        .onAppear {
            if case .rename(let playlist) = mode { name = playlist.name }
            isNameFocused = true
            // 打开时清掉上一次遗留的错误：否则用户会看到一条与本次操作无关的红字
            appState.clearWriteError()
        }
        .onDisappear {
            // 写失败时本 sheet 已经把错误显示在下面那行红字里了。必须在这里清掉，
            // 否则宿主页面的「操作失败」alert 会在本 sheet 关闭后才弹出来
            // （alert 盖不过 modal sheet，SwiftUI 会把它延后），
            // 于是同一个错误显示两遍，还晚一步。
            appState.clearWriteError()
        }
    }

    private func submit() {
        let trimmed = String(name.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isWorking else { return }
        isWorking = true
        Task {
            let ok = await onComplete(trimmed)
            isWorking = false
            if ok { onCancel() }
        }
    }
}

/// 确认删除歌单。
struct ConfirmDeletePlaylistSheet: View {
    let playlist: Playlist
    let onConfirm: () async -> Bool
    let onCancel: () -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: CTSpacing.lg) {
            Text("删除歌单")
                .font(CTTypography.sectionTitle)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))
            Text("确定要删除「\(playlist.name)」吗？此操作不可撤销。")
                .font(CTTypography.body)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            // 删除失败必须在这里就地显示：宿主页面的 alert 盖不过 modal sheet，
            // 不显示的话用户点了「删除」之后界面毫无反应，只能干等
            if let error = appState.lastWriteError {
                Text(error)
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.accent(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("删除", role: .destructive) {
                    isWorking = true
                    Task {
                        let ok = await onConfirm()
                        isWorking = false
                        if ok { onCancel() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            }
        }
        .padding(CTSpacing.xl)
        .frame(width: 360)
        .background(CTColors.panel(for: colorScheme))
        .onAppear { appState.clearWriteError() }
        .onDisappear { appState.clearWriteError() }
    }
}

/// 「添加到歌单」选择器。
///
/// 作为 context menu / sheet 的内容：列出可写的歌单 + 「新建歌单」。
struct AddToPlaylistSheet: View {
    let songs: [Song]
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var isWorking = false
    @State private var showCreate = false
    /// 内层「新建歌单」成功后要连带关掉本 sheet。
    /// 不能在内层的 onComplete 里直接 `dismiss()`：那一刻内层 sheet 还在屏幕上，
    /// 于是「外层 dismiss」与「内层 submit 结束时调的 onCancel」两条关闭路径同时生效。
    @State private var dismissAfterCreate = false
    @State private var resultMessage: String?

    private let provider = NeteaseProvider.shared

    private var targetSongIDs: [String] { songs.map(\.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CTSheetHeader(title: songs.count == 1 ? "添加到歌单" : "添加 \(songs.count) 首到歌单") {
                dismiss()
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: CTSpacing.xs) {
                    Button {
                        showCreate = true
                    } label: {
                        Label("新建歌单", systemImage: "plus.rectangle.on.folder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(CTSpacing.md)
                    .clipShape(RoundedRectangle(cornerRadius: CTRadius.small))

                    Divider().padding(.vertical, CTSpacing.xs)

                    if appState.userPlaylists.isEmpty {
                        Text("还没有创建歌单")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            .padding(CTSpacing.md)
                    } else {
                        ForEach(appState.userPlaylists) { playlist in
                            Button {
                                Task { await add(playlist) }
                            } label: {
                                HStack(spacing: CTSpacing.md) {
                                    CoverImage(url: playlist.coverURL, size: 36) {
                                        RoundedRectangle(cornerRadius: CTRadius.small)
                                            .fill(CTColors.overlay(for: colorScheme))
                                            .overlay(Image(systemName: "music.note.list").foregroundStyle(.secondary))
                                    }
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: CTRadius.small))

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(playlist.name)
                                            .font(CTTypography.bodyMedium)
                                            .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                                            .lineLimit(1)
                                        Text("\(playlist.trackCount) 首")
                                            .font(CTTypography.caption)
                                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                                    }
                                    Spacer()
                                    if isWorking {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isWorking)
                            .padding(CTSpacing.md)
                            .clipShape(RoundedRectangle(cornerRadius: CTRadius.small))
                        }
                    }
                }
                .padding(CTSpacing.sm)
            }
            .frame(maxHeight: 340)

            if let resultMessage {
                Divider()
                Text(resultMessage)
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    .padding(CTSpacing.lg)
            }
        }
        .frame(width: 380)
        .background(CTColors.panel(for: colorScheme))
        .onAppear { appState.clearWriteError() }
        .onDisappear {
            // `add(_:)` 把 lastWriteError 抄进了 resultMessage 显示在下方，
            // 但没清原件 —— 宿主页面（如 PlaylistDetailView）的「操作失败」alert
            // 会等本 sheet 关闭后再补弹一次，同一个错误显示两遍。
            appState.clearWriteError()
        }
        .sheet(isPresented: $showCreate, onDismiss: {
            // 只在内层已经收起之后才关外层，避免两条关闭路径打架
            if dismissAfterCreate {
                dismissAfterCreate = false
                dismiss()
            }
        }) {
            PlaylistNameSheet(mode: .create) { name in
                guard let created = await appState.createPlaylist(name: name, isPrivate: false) else {
                    return false
                }
                // 建完直接加进去，省得再点一次
                let ok = await appState.modifyPlaylist(created, songIDs: targetSongIDs, add: true)
                if ok { dismissAfterCreate = true }
                return ok
            } onCancel: {
                showCreate = false
            }
            .environmentObject(appState)
        }
    }

    private func add(_ playlist: Playlist) async {
        isWorking = true
        defer { isWorking = false }
        let ok = await appState.modifyPlaylist(playlist, songIDs: targetSongIDs, add: true)
        resultMessage = ok
            ? "已添加 \(targetSongIDs.count) 首到「\(playlist.name)」"
            : (appState.lastWriteError ?? "添加失败")
    }
}

/// 歌单的「更多」菜单：收藏 / 改名 / 删除。
///
/// 三处入口（搜索结果、我的音乐、歌单详情）都用它，保证行为一致。
struct PlaylistActionsMenu: View {
    let playlist: Playlist
    /// 是否是自己创建的歌单（决定能否改名/删除）
    var isOwned: Bool
    var isSubscribed: Bool
    let onSubscribe: (Bool) async -> Void
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?

    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            if appState.canPerformWrite {
                Button(isSubscribed ? "取消收藏" : "收藏歌单") {
                    Task { await onSubscribe(!isSubscribed) }
                }
            }
            if isOwned {
                Divider()
                if let onRename {
                    Button("重命名", action: onRename)
                }
                if let onDelete {
                    Divider()
                    Button("删除歌单", role: .destructive, action: onDelete)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .disabled(!appState.canPerformWrite)
        .help(appState.canPerformWrite ? "更多操作" : "登录后可管理歌单")
    }
}
