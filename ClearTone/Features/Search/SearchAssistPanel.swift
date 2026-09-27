import SwiftUI

/// 搜索框下拉面板：热搜 / 搜索历史 / 联想词。
///
/// 网易云的搜索框在未输入时展示热搜与历史，输入时展示联想下拉。
/// 三种状态互斥，由 `keyword` 是否为空决定。
struct SearchAssistPanel: View {
    let keyword: String
    let onPick: (String) -> Void
    let onPickSuggestion: (SearchSuggestion) -> Void
    /// 收起下拉。这是下拉面板**唯一**的关闭入口：
    /// 面板是 inline 的（把结果区往下推），不是浮窗，所以既没有「点击外部关闭」，
    /// 也没有窗口级 Esc；原先只能靠选中一项、切分类或输入框失焦来收起。
    let onClose: () -> Void

    @ObservedObject var store: SearchAssistStore
    @Environment(\.colorScheme) var colorScheme

    private var trimmed: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 细窄的关闭条。空关键词时下方已经有「搜索历史 / 热门搜索」两个分区头，
            // 再插一条完整页头会和它们打架，所以只放一个右对齐的关闭按钮。
            HStack {
                Spacer(minLength: 0)
                CTCloseButton(onClose: onClose)
            }
            .padding(.horizontal, CTSpacing.sm)
            .padding(.top, CTSpacing.xs)

            if !trimmed.isEmpty {
                suggestionList
            } else {
                historySection
                Divider().padding(.vertical, CTSpacing.sm)
                hotSection
            }
        }
        .onExitCommand { onClose() }
        .background(CTColors.panel(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: CTRadius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: CTRadius.medium)
                .stroke(CTColors.overlay(for: colorScheme), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    // MARK: - 联想

    @ViewBuilder
    private var suggestionList: some View {
        if store.isLoadingSuggestions && store.suggestions.isEmpty {
            HStack(spacing: CTSpacing.sm) {
                ProgressView().controlSize(.small)
                Text("搜索中...").font(CTTypography.caption).foregroundStyle(.secondary)
            }
            .padding(CTSpacing.lg)
        } else if store.suggestions.isEmpty {
            Text("没有联想结果")
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                .padding(CTSpacing.lg)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.suggestions) { suggestion in
                        Button {
                            onPickSuggestion(suggestion)
                        } label: {
                            HStack(spacing: CTSpacing.md) {
                                Image(systemName: icon(for: suggestion.kind))
                                    .font(.caption)
                                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.title)
                                        .font(CTTypography.bodyMedium)
                                        .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                                        .lineLimit(1)
                                    if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
                                        Text(subtitle)
                                            .font(CTTypography.caption)
                                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                Text(label(for: suggestion.kind))
                                    .font(.caption2)
                                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            }
                            .padding(.horizontal, CTSpacing.lg)
                            .padding(.vertical, CTSpacing.sm)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private func icon(for kind: SearchSuggestion.Kind) -> String {
        switch kind {
        case .song: return "music.note"
        case .artist: return "person"
        case .album: return "square.stack"
        case .playlist: return "music.note.list"
        }
    }

    private func label(for kind: SearchSuggestion.Kind) -> String {
        switch kind {
        case .song: return "单曲"
        case .artist: return "歌手"
        case .album: return "专辑"
        case .playlist: return "歌单"
        }
    }

    // MARK: - 历史

    @ViewBuilder
    private var historySection: some View {
        HStack {
            Label("搜索历史", systemImage: "clock.arrow.circlepath")
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            Spacer()
            if !store.history.isEmpty {
                Button("清空") { store.clearHistory() }
                    .buttonStyle(.plain)
                    .font(CTTypography.caption)
            }
        }
        .padding(.horizontal, CTSpacing.lg)
        .padding(.top, CTSpacing.md)
        .padding(.bottom, CTSpacing.xs)

        if store.history.isEmpty {
            Text("暂无搜索历史")
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                .padding(.horizontal, CTSpacing.lg)
                .padding(.bottom, CTSpacing.md)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.history, id: \.self) { term in
                        HStack {
                            Button {
                                onPick(term)
                            } label: {
                                Label(term, systemImage: "magnifyingglass")
                                    .font(CTTypography.body)
                                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button {
                                store.removeHistory(term)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除历史：\(term)")
                        }
                        .padding(.horizontal, CTSpacing.lg)
                        .padding(.vertical, CTSpacing.xs)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    // MARK: - 热搜

    @ViewBuilder
    private var hotSection: some View {
        HStack {
            Label("热门搜索", systemImage: "flame")
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            Spacer()
            if store.isLoadingHot {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, CTSpacing.lg)
        .padding(.bottom, CTSpacing.xs)

        if let error = store.hotError {
            HStack {
                Text(error)
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                Spacer()
                Button("重试") { Task { await store.loadHotTerms() } }
                    .buttonStyle(.plain)
                    .font(CTTypography.caption)
            }
            .padding(.horizontal, CTSpacing.lg)
            .padding(.bottom, CTSpacing.md)
        } else if store.hotTerms.isEmpty && !store.isLoadingHot {
            Text("暂无热搜数据")
                .font(CTTypography.caption)
                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                .padding(.horizontal, CTSpacing.lg)
                .padding(.bottom, CTSpacing.md)
        } else {
            ScrollView {
                // 两列瀑布式排布，避免热搜词全挤在一行
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                          alignment: .leading, spacing: CTSpacing.xs) {
                    ForEach(store.hotTerms) { term in
                        Button {
                            onPick(term.keyword)
                        } label: {
                            HStack(spacing: 4) {
                                if let icon = term.icon, !icon.isEmpty {
                                    Text(icon).font(.caption)
                                }
                                Text(term.keyword)
                                    .font(CTTypography.caption)
                                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, CTSpacing.lg)
                .padding(.bottom, CTSpacing.md)
            }
            .frame(maxHeight: 200)
        }
    }
}
