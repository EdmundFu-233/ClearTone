import Foundation

/// 评论状态机所需的最小接口，允许离线测试注入受控响应。
public protocol CommentProvider: Sendable {
    func fetchComments(songID: String, sort: CommentSort, page: Int, pageSize: Int, cursor: String?) async throws -> CommentPage
    func likeComment(songID: String, commentID: String, like: Bool) async throws
}
