import SwiftUI

/// 账号页：听歌等级 / 每日打卡 / 听歌排行。
struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    @StateObject private var store = ProfileStore()

    var body: some View {
        VStack(spacing: 0) {
            CTPageHeader(title: "我的", subtitle: "听歌等级与记录。", icon: "person.crop.circle")
                .padding(CTSpacing.xl)

            if !appState.canPerformWrite {
                LoginRequiredView(feature: "听歌等级与记录")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: CTSpacing.xl) {
                        levelCard
                        signInCard
                        recordsSection
                    }
                    .padding(CTSpacing.xl)
                }
            }
        }
        .background(CTColors.background(for: colorScheme))
        .task(id: appState.dataContextKey) {
            async let a: Void = store.loadLevel()
            async let b: Void = store.loadRecords()
            _ = await (a, b)
        }
    }

    // MARK: - 等级

    @ViewBuilder
    private var levelCard: some View {
        VStack(alignment: .leading, spacing: CTSpacing.md) {
            HStack {
                Label("听歌等级", systemImage: "crown")
                    .font(CTTypography.sectionTitle)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                Spacer()
                if store.isLoadingLevel {
                    ProgressView().controlSize(.small)
                } else if let level = store.level {
                    Text("Lv.\(level.level)")
                        .font(.title2)
                        .foregroundStyle(CTColors.accent(for: colorScheme))
                }
            }

            if let level = store.level {
                VStack(alignment: .leading, spacing: CTSpacing.sm) {
                    // 进度条宽度不能为 0/1 之外的值，否则 ProgressView 崩溃
                    ProgressView(value: min(max(level.progressFraction, 0), 1))
                        .progressViewStyle(.linear)
                    HStack {
                        stat("累计听歌", "\(level.listenSongs) 首")
                        stat("累计天数", "\(level.listenDays) 天")
                        Spacer()
                        if level.nextLevelNeedLoginDays > 0 {
                            Text("再听 \(level.remainingLoginDays) 天升级")
                                .font(CTTypography.caption)
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        } else {
                            Text("已是最高等级")
                                .font(CTTypography.caption)
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        }
                    }
                }
            } else if let error = store.levelError {
                ErrorView(message: error) { Task { await store.loadLevel() } }
                .frame(height: 120)
            }
        }
        .padding(CTSpacing.lg)
        .background(CTColors.panel(for: colorScheme), in: RoundedRectangle(cornerRadius: CTRadius.large))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(CTTypography.bodyMedium)
                .foregroundStyle(CTColors.textPrimary(for: colorScheme))
            Text(label)
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
        }
    }

    // MARK: - 打卡

    private var signInCard: some View {
        HStack(spacing: CTSpacing.lg) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 32))
                .foregroundStyle(CTColors.accent(for: colorScheme))
            VStack(alignment: .leading, spacing: 3) {
                Text("每日打卡")
                    .font(CTTypography.bodyMedium)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                Text(signInSubtitle)
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            }
            Spacer()
            signInButton
        }
        .padding(CTSpacing.lg)
        .background(CTColors.panel(for: colorScheme), in: RoundedRectangle(cornerRadius: CTRadius.large))
    }

    private var signInSubtitle: String {
        switch store.signInResult {
        case .success(let point): return "打卡成功，获得 \(point) 成长值"
        case .alreadySigned: return "今天已经打过卡了"
        case .failed(let message): return message
        case nil: return "连续登录可提升听歌等级"
        }
    }

    @ViewBuilder
    private var signInButton: some View {
        switch store.signInResult {
        case .success:
            Label("已打卡", systemImage: "checkmark")
                .font(CTTypography.body)
                .foregroundStyle(CTColors.accent(for: colorScheme))
        case .alreadySigned:
            Button("重新加载") { Task { await store.loadLevel() } }
                .buttonStyle(.bordered)
        default:
            Button {
                Task { await store.signIn() }
            } label: {
                if store.isSigningIn {
                    ProgressView().controlSize(.small)
                } else {
                    Text("打卡")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isSigningIn || !appState.canPerformWrite)
        }
    }

    // MARK: - 听歌排行

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: CTSpacing.md) {
            HStack {
                Label("听歌排行", systemImage: "list.bullet.rectangle")
                    .font(CTTypography.sectionTitle)
                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                Spacer()
                Picker("范围", selection: $store.recordsWeekly) {
                    Text("全部").tag(false)
                    Text("最近一周").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                if !store.records.isEmpty {
                    Button {
                        player.play(songs: store.records.map(\.song), startAt: 0)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if store.isLoadingRecords {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let error = store.recordsError {
                ErrorView(message: error) { Task { await store.loadRecords() } }
                    .frame(minHeight: 160)
            } else if store.records.isEmpty {
                EmptyStateView(
                    icon: "list.bullet.rectangle",
                    title: "听歌排行",
                    message: store.recordsWeekly ? "最近一周还没有播放记录" : "还没有播放记录"
                )
                .frame(minHeight: 180)
            } else {
                List(store.records, id: \.id) { record in
                    HStack(spacing: CTSpacing.md) {
                        Text("\(record.playCount)")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                        SongRowView(song: record.song) {
                            let songs = store.records.map(\.song)
                            player.play(songs: songs, startAt: songs.firstIndex(of: record.song) ?? 0)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 360)
            }
        }
    }
}
