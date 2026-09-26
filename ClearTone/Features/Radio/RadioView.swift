import SwiftUI

/// 电台列表页：分类筛选 + 精选推荐 + 热门电台
struct RadioView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme

    @State private var categories: [RadioCategory] = []
    @State private var selectedCategoryID: String?
    @State private var radios: [RadioStation] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// 加载代次：切换分类时旧请求不得写入
    @State private var loadToken = UUID()

    private let provider = NeteaseProvider.shared

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: CTSpacing.lg)]

    var body: some View {
        VStack(spacing: 0) {
            CTPageHeader(title: "电台", subtitle: "主播的声音，长音频节目。", icon: "dot.radiowaves.left.and.right")
                .padding(CTSpacing.xl)

            if !categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CTSpacing.sm) {
                        categoryChip(title: "全部", id: nil)
                        ForEach(categories) { category in
                            categoryChip(title: category.name, id: category.id)
                        }
                    }
                    .padding(.horizontal, CTSpacing.xl)
                    .padding(.bottom, CTSpacing.md)
                }
            }

            if isLoading && radios.isEmpty {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, radios.isEmpty {
                ErrorView(message: errorMessage) { Task { await load() } }
            } else if radios.isEmpty {
                EmptyStateView(icon: "dot.radiowaves.left.and.right", title: "电台",
                               message: "没有找到电台")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: CTSpacing.lg) {
                        ForEach(radios) { radio in
                            RadioCardView(radio: radio) {
                                appState.selectedRadioID = radio.id
                                appState.currentPage = .radioDetail
                            }
                        }
                    }
                    .padding(CTSpacing.xl)
                }
            }
        }
        .background(CTColors.background(for: colorScheme))
        .task { await loadCategoriesIfNeeded() }
        .task(id: selectedCategoryID) { await load() }
    }

    private func categoryChip(title: String, id: String?) -> some View {
        let isSelected = selectedCategoryID == id
        return Text(title)
            .font(CTTypography.caption)
            .foregroundStyle(isSelected ? Color.white : CTColors.textSecondary(for: colorScheme))
            .padding(.horizontal, CTSpacing.md)
            .padding(.vertical, 6)
            .background(isSelected ? CTColors.accent(for: colorScheme) : CTColors.overlay(for: colorScheme))
            .cornerRadius(CTRadius.small)
            .onTapGesture { selectedCategoryID = id }
    }

    private func loadCategoriesIfNeeded() async {
        guard categories.isEmpty else { return }
        categories = (try? await provider.fetchRadioCategories()) ?? []
    }

    private func load() async {
        let token = UUID()
        loadToken = token
        isLoading = true
        errorMessage = nil
        do {
            let loaded: [RadioStation]
            if let selectedCategoryID, !selectedCategoryID.isEmpty {
                loaded = try await provider.fetchHotRadios(categoryID: selectedCategoryID, limit: 40)
            } else {
                // 「全部」优先用精选推荐（质量更高），失败再退到热门榜。
                // ?? 的右侧是 autoclosure，不能直接放 await，所以分开写。
                if let recommended = try? await provider.fetchRecommendedRadios(limit: 40), !recommended.isEmpty {
                    loaded = recommended
                } else {
                    loaded = try await provider.fetchHotRadios(limit: 40)
                }
            }
            guard loadToken == token, !Task.isCancelled else { return }
            radios = loaded
        } catch {
            guard loadToken == token else { return }
            errorMessage = CTLog.sanitize(error.localizedDescription)
        }
        guard loadToken == token else { return }
        isLoading = false
    }
}

/// 电台卡片
struct RadioCardView: View {
    let radio: RadioStation
    var onTap: (() -> Void)?
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button { onTap?() } label: {
            VStack(alignment: .leading, spacing: CTSpacing.sm) {
                CoverImage(url: radio.coverURL, size: 170,
                           cornerRadius: CTRadius.medium,
                           systemImage: "dot.radiowaves.left.and.right",
                           tint: CTColors.textSecondary(for: colorScheme))
                .frame(height: 170)
                .clipped()
                .cornerRadius(CTRadius.medium)

                Text(radio.name)
                    .font(CTTypography.bodyMedium)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                    .lineLimit(1)

                HStack(spacing: CTSpacing.xs) {
                    if let creator = radio.creatorName {
                        Text(creator)
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            .lineLimit(1)
                    }
                    if radio.programCount > 0 {
                        Text("· \(radio.programCount) 期")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 0.85 : 1)
        .onHover { isHovering = $0 }
        .help("打开电台：\(radio.name)")
    }
}

/// 电台详情：节目列表
struct RadioDetailView: View {
    let radioID: String
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    @State private var station: RadioStation?
    @State private var programs: [RadioProgram] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadToken = UUID()

    private let provider = NeteaseProvider.shared
    private let pageSize = 30

    /// 可播放的节目（按时间倒序，最新在前）
    private var playablePrograms: [RadioProgram] { programs.filter(\.isPlayable) }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading && station == nil {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, station == nil {
                ErrorView(message: errorMessage) { Task { await load() } }
            } else {
                header
                Divider()
                programList
            }
        }
        .background(CTColors.background(for: colorScheme))
        .task(id: radioID) { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: CTSpacing.lg) {
            CoverImage(url: station?.coverURL, size: 160,
                       cornerRadius: CTRadius.medium,
                       systemImage: "dot.radiowaves.left.and.right",
                       tint: CTColors.textSecondary(for: colorScheme))
            .frame(width: 160, height: 160)
            .clipped()
            .cornerRadius(CTRadius.medium)

            VStack(alignment: .leading, spacing: CTSpacing.sm) {
                Text(station?.name ?? "电台")
                    .font(CTTypography.pageTitle)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))

                if let creator = station?.creatorName {
                    Text("主播：\(creator)")
                        .font(CTTypography.caption)
                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                }
                HStack(spacing: CTSpacing.md) {
                    if let count = station?.programCount, count > 0 {
                        Label("\(count) 期", systemImage: "list.bullet")
                    }
                    if let subs = station?.subscriberCount, subs > 0 {
                        Label("\(subs) 订阅", systemImage: "person.2")
                    }
                }
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))

                if !playablePrograms.isEmpty {
                    Button {
                        player.play(songs: playablePrograms.compactMap(\.song))
                    } label: {
                        Label("播放全部节目", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(playablePrograms.isEmpty)
                }
            }
            Spacer()
        }
        .padding(CTSpacing.xl)
    }

    @ViewBuilder
    private var programList: some View {
        if programs.isEmpty {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(icon: "waveform", title: "节目", message: "该电台还没有节目")
            }
        } else {
            List(playablePrograms) { program in
                RadioProgramRow(program: program) {
                    player.play(songs: playablePrograms.compactMap(\.song),
                                startAt: playablePrograms.firstIndex(of: program) ?? 0)
                }
            }
            .listStyle(.plain)
        }
    }

    private func load() async {
        let token = UUID()
        loadToken = token
        isLoading = true
        errorMessage = nil
        do {
            // 节目按时间倒序更有意义：网易云默认按创建时间升序，这里取最新在前
            let loaded = try await provider.fetchRadioPrograms(radioID: radioID, page: 1, limit: pageSize)
            guard loadToken == token, !Task.isCancelled else { return }
            programs = loaded.reversed().map { $0 }
            // 电台名称：从节目里带不出来（dj/program 不返回电台名），
            // 单独查一次热门/推荐列表代价大，这里用节目数兜底展示
            if station == nil {
                station = RadioStation(id: radioID, name: "电台",
                                       programCount: loaded.count)
            }
        } catch {
            guard loadToken == token else { return }
            errorMessage = CTLog.sanitize(error.localizedDescription)
        }
        guard loadToken == token else { return }
        isLoading = false
    }
}

/// 节目行
struct RadioProgramRow: View {
    let program: RadioProgram
    var onPlay: () -> Void
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovering = false

    private var isCurrent: Bool {
        guard let id = program.song?.id else { return false }
        return player.currentSong?.id == id
    }

    var body: some View {
        HStack(spacing: CTSpacing.md) {
            CoverImage(url: program.coverURL, size: 44,
                       cornerRadius: CTRadius.small,
                       systemImage: "waveform",
                       tint: CTColors.textSecondary(for: colorScheme))
            .frame(width: 44, height: 44)
            .cornerRadius(CTRadius.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(program.title)
                    .font(CTTypography.bodyMedium)
                    .foregroundStyle(isCurrent ? CTColors.accent(for: colorScheme)
                                              : CTColors.textPrimary(for: colorScheme))
                    .lineLimit(2)
                HStack(spacing: CTSpacing.xs) {
                    if program.duration > 0 {
                        Text(Self.format(program.duration))
                    }
                    if let date = program.createTime {
                        Text(Self.dateFormatter.string(from: date))
                    }
                    if program.playCount > 0 {
                        Text("\(program.playCount) 次播放")
                    }
                }
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            }

            Spacer()

            Button(action: onPlay) {
                Image(systemName: isCurrent && player.playbackState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(CTColors.accent(for: colorScheme))
            }
            .buttonStyle(.plain)
            .help("播放这一期")
        }
        .contentShape(Rectangle())
        // 双击播放，与其它歌曲列表一致
        .onTapGesture(count: 2) { onPlay() }
        .opacity(isHovering ? 0.85 : 1)
        .onHover { isHovering = $0 }
    }

    /// 长音频常超过 1 小时，用「时:分:秒」而不是「分:秒」
    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
