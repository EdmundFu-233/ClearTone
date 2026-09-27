import Foundation
import Combine

/// 消息中心：通知 / 私信会话 / 我发出的评论。
@MainActor
final class SocialStore: ObservableObject {

    enum Tab: String, CaseIterable, Identifiable {
        case notices = "通知"
        case conversations = "私信"
        case myComments = "我的评论"
        var id: String { rawValue }
    }

    // MARK: - 通知

    @Published private(set) var notices: [UserNotice] = []
    @Published private(set) var isLoadingNotices = false
    @Published private(set) var noticesError: String?
    private var noticeToken = UUID()

    func loadNotices() async {
        let token = UUID()
        noticeToken = token
        isLoadingNotices = notices.isEmpty
        noticesError = nil
        do {
            let loaded = try await NeteaseProvider.shared.fetchNotices(limit: 30)
            guard noticeToken == token, !Task.isCancelled else { return }
            notices = loaded
        } catch {
            guard noticeToken == token else { return }
            noticesError = error.ctUserMessage
        }
        guard noticeToken == token else { return }
        isLoadingNotices = false
    }

    // MARK: - 私信

    @Published private(set) var conversations: [PrivateConversation] = []
    @Published private(set) var isLoadingConversations = false
    @Published private(set) var conversationsError: String?
    private var conversationToken = UUID()

    func loadConversations() async {
        let token = UUID()
        conversationToken = token
        isLoadingConversations = conversations.isEmpty
        conversationsError = nil
        do {
            let loaded = try await NeteaseProvider.shared.fetchPrivateConversations(limit: 30, offset: 0)
            guard conversationToken == token, !Task.isCancelled else { return }
            conversations = loaded
        } catch {
            guard conversationToken == token else { return }
            conversationsError = error.ctUserMessage
        }
        guard conversationToken == token else { return }
        isLoadingConversations = false
    }

    // MARK: - 私信详情

    @Published var selectedConversation: PrivateConversation?
    @Published private(set) var messages: [PrivateMessage] = []
    @Published private(set) var isLoadingMessages = false
    @Published private(set) var messagesError: String?
    private var messageToken = UUID()

    func openConversation(_ conversation: PrivateConversation) async {
        selectedConversation = conversation
        messages = []
        messagesError = nil
        let token = UUID()
        messageToken = token
        isLoadingMessages = true
        do {
            let loaded = try await NeteaseProvider.shared.fetchPrivateMessages(
                userID: conversation.userID, limit: 50
            )
            guard messageToken == token, !Task.isCancelled else { return }
            messages = loaded
            // 打开即已读
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }),
               conversations[index].unreadCount > 0 {
                conversations[index].unreadCount = 0
            }
        } catch {
            guard messageToken == token else { return }
            messagesError = error.ctUserMessage
        }
        guard messageToken == token else { return }
        isLoadingMessages = false
    }

    func closeConversation() {
        selectedConversation = nil
        messages = []
        messageToken = UUID()
    }

    // MARK: - 我的评论

    @Published private(set) var myComments: [MyComment] = []
    @Published private(set) var isLoadingMyComments = false
    @Published private(set) var myCommentsError: String?
    private var myCommentToken = UUID()

    func loadMyComments() async {
        let token = UUID()
        myCommentToken = token
        isLoadingMyComments = myComments.isEmpty
        myCommentsError = nil
        do {
            let loaded = try await NeteaseProvider.shared.fetchMyComments(limit: 30)
            guard myCommentToken == token, !Task.isCancelled else { return }
            myComments = loaded
        } catch {
            guard myCommentToken == token else { return }
            myCommentsError = error.ctUserMessage
        }
        guard myCommentToken == token else { return }
        isLoadingMyComments = false
    }
}
