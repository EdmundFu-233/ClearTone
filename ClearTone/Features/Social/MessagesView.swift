import SwiftUI

/// 消息中心：通知 / 私信 / 我的评论。
struct MessagesView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.colorScheme) var colorScheme

    @StateObject private var store = SocialStore()

    var body: some View {
        VStack(spacing: 0) {
            CTPageHeader(title: "消息", subtitle: "评论、回复与私信都在这里。", icon: "bell")
                .padding(CTSpacing.xl)

            if !appState.canPerformWrite {
                LoginRequiredView(feature: "消息")
            } else {
                Picker("分类", selection: tabBinding) {
                    ForEach(SocialStore.Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, CTSpacing.xl)
                .padding(.bottom, CTSpacing.md)

                Group {
                    switch tab {
                    case .notices: noticesPane
                    case .conversations: conversationsPane
                    case .myComments: myCommentsPane
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CTColors.background(for: colorScheme))
        .task(id: appState.dataContextKey) { await loadCurrentTab() }
        .onChange(of: store.selectedConversation?.id) { _, newValue in
            // 选中项被清空（关闭详情）时不该再拉数据
            if newValue == nil { store.closeConversation() }
        }
    }

    @State private var tab: SocialStore.Tab = .notices
    private var tabBinding: Binding<SocialStore.Tab> {
        Binding(get: { tab }, set: { newValue in
            tab = newValue
            store.selectedConversation = nil
            Task { await load(newValue) }
        })
    }

    // MARK: - 通知

    @ViewBuilder
    private var noticesPane: some View {
        if store.isLoadingNotices {
            ProgressView("加载中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.noticesError {
            ErrorView(message: error) { Task { await store.loadNotices() } }
        } else if store.notices.isEmpty {
            EmptyStateView(icon: "bell", title: "通知", message: "暂时没有新通知")
        } else {
            List(store.notices) { notice in
                HStack(alignment: .top, spacing: CTSpacing.md) {
                    AvatarView(url: notice.actorAvatarURL, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: CTSpacing.sm) {
                            Label(notice.kind.label, systemImage: notice.kind.systemImage)
                                .font(CTTypography.caption)
                                .foregroundStyle(CTColors.accent(for: colorScheme))
                            if let who = notice.actorNickname {
                                Text(who)
                                    .font(CTTypography.bodyMedium)
                                    .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                            }
                            Spacer()
                            Text(CommentRow.relativeTime(notice.time))
                                .font(CTTypography.caption)
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        }
                        if let content = notice.content, !content.isEmpty {
                            Text(content)
                                .font(CTTypography.body)
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                                .lineLimit(3)
                        }
                        if let reply = notice.replyCommentText, !reply.isEmpty {
                            Text("「\(reply)」")
                                .font(CTTypography.caption)
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                                .lineLimit(2)
                                .padding(CTSpacing.xs)
                                .background(CTColors.overlay(for: colorScheme))
                                .clipShape(RoundedRectangle(cornerRadius: CTRadius.small))
                        }
                    }
                }
                .padding(.vertical, CTSpacing.xs)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await store.loadNotices() }
        }
    }

    // MARK: - 私信

    @ViewBuilder
    private var conversationsPane: some View {
        if let conversation = store.selectedConversation {
            conversationDetail(conversation)
        } else if store.isLoadingConversations {
            ProgressView("加载中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.conversationsError {
            ErrorView(message: error) { Task { await store.loadConversations() } }
        } else if store.conversations.isEmpty {
            EmptyStateView(icon: "text.bubble", title: "私信", message: "没有私信会话")
        } else {
            List(store.conversations) { conversation in
                Button {
                    Task { await store.openConversation(conversation) }
                } label: {
                    HStack(spacing: CTSpacing.md) {
                        AvatarView(url: conversation.avatarURL, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.nickname)
                                .font(CTTypography.bodyMedium)
                                .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                            if let last = conversation.lastMessage {
                                Text(last)
                                    .font(CTTypography.caption)
                                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            if let time = conversation.lastTime {
                                Text(CommentRow.relativeTime(time))
                                    .font(CTTypography.caption)
                                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            }
                            if conversation.unreadCount > 0 {
                                Text("\(conversation.unreadCount)")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(CTColors.accent(for: colorScheme))
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开与 \(conversation.nickname) 的私信")
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await store.loadConversations() }
        }
    }

    private func conversationDetail(_ conversation: PrivateConversation) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    store.closeConversation()
                } label: {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
                Text(conversation.nickname)
                    .font(CTTypography.sectionTitle)
                Spacer()
                // 右侧留白，让标题真正居中
                Color.clear.frame(width: 60, height: 1)
            }
            .padding(CTSpacing.lg)

            Divider()

            if store.isLoadingMessages {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.messagesError {
                ErrorView(message: error) {
                    Task { await store.openConversation(conversation) }
                }
            } else if store.messages.isEmpty {
                EmptyStateView(icon: "text.bubble", title: "私信", message: "没有消息记录")
            } else {
                ScrollView {
                    VStack(spacing: CTSpacing.md) {
                        ForEach(store.messages) { message in
                            HStack {
                                if message.isOutgoing { Spacer(minLength: 40) }
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 4) {
                                        Image(systemName: message.kind.systemImage)
                                            .font(.caption2)
                                        if message.kind.systemImage != "text.bubble" {
                                            Text(message.kind.systemImage == "music.note" ? "歌曲" : "卡片")
                                                .font(.caption2)
                                        }
                                    }
                                    .foregroundStyle(.secondary)
                                    Text(message.content)
                                        .font(CTTypography.body)
                                        .textSelection(.enabled)
                                    Text(CommentRow.relativeTime(message.time))
                                        .font(.caption2)
                                        .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                                }
                                .padding(CTSpacing.md)
                                .background(
                                    message.isOutgoing
                                        ? CTColors.accentSubtle(for: colorScheme)
                                        : CTColors.overlay(for: colorScheme)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: CTRadius.medium))
                                if !message.isOutgoing { Spacer(minLength: 40) }
                            }
                        }
                    }
                    .padding(CTSpacing.lg)
                }
            }

            Divider()
            HStack(spacing: CTSpacing.sm) {
                Image(systemName: "paperplane")
                    .foregroundStyle(.secondary)
                Text("发送私信依赖网易云的反作弊校验，当前版本仅支持阅读")
                    .font(CTTypography.caption)
                    .foregroundStyle(CTColors.textSecondary(for: colorScheme))
            }
            .padding(CTSpacing.lg)
        }
    }

    // MARK: - 我的评论

    @ViewBuilder
    private var myCommentsPane: some View {
        if store.isLoadingMyComments {
            ProgressView("加载中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.myCommentsError {
            ErrorView(message: error) { Task { await store.loadMyComments() } }
        } else if store.myComments.isEmpty {
            EmptyStateView(icon: "text.bubble", title: "我的评论", message: "还没有发表过评论")
        } else {
            List(store.myComments) { item in
                VStack(alignment: .leading, spacing: CTSpacing.xs) {
                    HStack(spacing: CTSpacing.sm) {
                        Label(item.resourceKind.label, systemImage: "quote.opening")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.accent(for: colorScheme))
                        Text(CommentRow.relativeTime(item.time))
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        if item.likedCount > 0 {
                            Label("\(item.likedCount)", systemImage: "hand.thumbsup")
                                .font(CTTypography.caption)
                                .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                        }
                        Spacer()
                    }
                    if let who = item.repliedNickname {
                        Text("回复 @\(who)：\(item.repliedContent ?? "")")
                            .font(CTTypography.caption)
                            .foregroundStyle(CTColors.textSecondary(for: colorScheme))
                            .lineLimit(2)
                    }
                    Text(item.content)
                        .font(CTTypography.body)
                        .foregroundStyle(CTColors.textPrimary(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, CTSpacing.xs)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await store.loadMyComments() }
        }
    }

    // MARK: - 加载

    private func loadCurrentTab() async {
        await load(tab)
    }

    private func load(_ tab: SocialStore.Tab) async {
        switch tab {
        case .notices: await store.loadNotices()
        case .conversations: await store.loadConversations()
        case .myComments: await store.loadMyComments()
        }
    }
}
