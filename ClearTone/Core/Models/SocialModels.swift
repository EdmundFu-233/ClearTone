import Foundation

// MARK: - 评论

/// 评论排序（`/comment/new` 的 `sortType`）
public enum CommentSort: String, CaseIterable, Sendable, Identifiable {
    /// 按推荐
    case recommended = "推荐"
    /// 按热度
    case hot = "热度"
    /// 按时间
    case newest = "最新"

    public var id: String { rawValue }

    /// 接口值。注意 `1` 会被 `comment_new.js` 强制改写成 `99`，
    /// 所以这里不用 1 表示「推荐」。
    public var apiValue: Int {
        switch self {
        case .recommended: return 99
        case .hot: return 2
        case .newest: return 3
        }
    }
}

/// 一条评论。
public struct Comment: Identifiable, Hashable, Sendable {
    public var id: String
    public var content: String
    public var userID: String
    public var nickname: String
    public var avatarURL: URL?
    /// 发布时间
    public var time: Date
    public var likedCount: Int
    /// 当前登录用户是否已点赞
    public var isLiked: Bool
    public var replyCount: Int
    /// 被回复的评论摘要（`beReplied[0]`）
    public var replyToNickname: String?
    public var replyToContent: String?
    /// 是否为当前用户自己发的（决定能否删除）
    public var isMine: Bool

    public init(id: String, content: String, userID: String, nickname: String,
                avatarURL: URL? = nil, time: Date, likedCount: Int = 0,
                isLiked: Bool = false, replyCount: Int = 0,
                replyToNickname: String? = nil, replyToContent: String? = nil,
                isMine: Bool = false) {
        self.id = id; self.content = content; self.userID = userID
        self.nickname = nickname; self.avatarURL = avatarURL; self.time = time
        self.likedCount = likedCount; self.isLiked = isLiked
        self.replyCount = replyCount; self.replyToNickname = replyToNickname
        self.replyToContent = replyToContent; self.isMine = isMine
    }
}

/// 一页评论。
public struct CommentPage: Sendable {
    public var comments: [Comment]
    public var total: Int
    public var hasMore: Bool

    public init(comments: [Comment] = [], total: Int = 0, hasMore: Bool = false) {
        self.comments = comments; self.total = total; self.hasMore = hasMore
    }
}

// MARK: - 消息

/// 通知（`/msg/notices`）
public struct UserNotice: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable, Hashable {
        case comment       // 有人评论了我
        case reply         // 有人回复了我
        case follow        // 有人关注我
        case like          // 有人赞了我
        case unknown(Int)  // 接口未文档化的类型码

        /// 类型码 → 展示名。api-enhanced 的 `msg_notices.js` 没有注释，
        /// 这里按网易云客户端的既有约定映射，未知类型原样保留。
        public init(typeCode: Int) {
            switch typeCode {
            case 1: self = .comment
            case 2: self = .reply
            case 3: self = .like
            case 4: self = .follow
            default: self = .unknown(typeCode)
            }
        }

        public var systemImage: String {
            switch self {
            case .comment: return "text.bubble"
            case .reply: return "arrowshape.turn.up.left"
            case .follow: return "person.badge.plus"
            case .like: return "hand.thumbsup"
            case .unknown: return "bell"
            }
        }

        public var label: String {
            switch self {
            case .comment: return "评论"
            case .reply: return "回复"
            case .follow: return "关注"
            case .like: return "赞"
            case .unknown: return "通知"
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var time: Date
    /// 触发者的昵称
    public var actorNickname: String?
    public var actorAvatarURL: URL?
    /// 评论/回复的正文
    public var content: String?
    /// 「回复」类型里指向的评论正文
    public var replyCommentText: String?
    /// 被评论的资源 id（可据此跳转到歌曲页）
    public var relatedID: String?

    public init(id: String, kind: Kind, time: Date, actorNickname: String? = nil,
                actorAvatarURL: URL? = nil, content: String? = nil,
                replyCommentText: String? = nil, relatedID: String? = nil) {
        self.id = id; self.kind = kind; self.time = time
        self.actorNickname = actorNickname; self.actorAvatarURL = actorAvatarURL
        self.content = content; self.replyCommentText = replyCommentText
        self.relatedID = relatedID
    }
}

/// 私信会话（`/msg/private`）
///
/// 注意：`/msg/private` 返回的是**会话列表**而不是消息历史，
/// 消息历史要用 `/msg/private/history?uid=`。
public struct PrivateConversation: Identifiable, Hashable, Sendable {
    public var id: String
    public var userID: String
    public var nickname: String
    public var avatarURL: URL?
    public var lastMessage: String?
    public var lastTime: Date?
    public var unreadCount: Int

    public init(id: String, userID: String, nickname: String, avatarURL: URL? = nil,
                lastMessage: String? = nil, lastTime: Date? = nil, unreadCount: Int = 0) {
        self.id = id; self.userID = userID; self.nickname = nickname
        self.avatarURL = avatarURL; self.lastMessage = lastMessage
        self.lastTime = lastTime; self.unreadCount = unreadCount
    }
}

/// 一条私信（`/msg/private/history`）
public struct PrivateMessage: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable, Hashable {
        case text, image, song, album, playlist, unknown(Int)

        public init(msgType: Int) {
            switch msgType {
            case 1: self = .text
            case 2: self = .image
            case 3: self = .song
            case 4: self = .album
            case 5: self = .playlist
            default: self = .unknown(msgType)
            }
        }

        public var systemImage: String {
            switch self {
            case .text: return "text.bubble"
            case .image: return "photo"
            case .song: return "music.note"
            case .album: return "square.stack"
            case .playlist: return "music.note.list"
            case .unknown: return "questionmark.bubble"
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var content: String
    public var time: Date
    /// 是否是自己发出的（决定左右气泡）
    public var isOutgoing: Bool
    public var senderNickname: String?

    public init(id: String, kind: Kind, content: String, time: Date,
                isOutgoing: Bool, senderNickname: String? = nil) {
        self.id = id; self.kind = kind; self.content = content
        self.time = time; self.isOutgoing = isOutgoing
        self.senderNickname = senderNickname
    }
}

/// 「我发出的评论」条目（`/msg/comments`）
public struct MyComment: Identifiable, Hashable, Sendable {
    /// 网易云的资源类型码。0=歌曲 1=MV 2=歌单 3=专辑 4=电台 …
    public enum ResourceKind: Int, Sendable, Hashable {
        case song = 0, mv = 1, playlist = 2, album = 3, radio = 4, video = 5, event = 6, drama = 7

        public var label: String {
            switch self {
            case .song: return "歌曲"
            case .mv: return "MV"
            case .playlist: return "歌单"
            case .album: return "专辑"
            case .radio: return "电台"
            case .video: return "视频"
            case .event: return "动态"
            case .drama: return "广播剧"
            }
        }

        /// 本应用有对应详情页的类型
        public var isNavigable: Bool {
            switch self {
            case .song, .playlist, .album: return true
            default: return false
            }
        }
    }

    public var id: String
    public var content: String
    public var time: Date
    public var likedCount: Int
    /// 被评论的资源类型
    public var resourceKind: ResourceKind
    /// 被评论的资源 id（`/msg/comments` 只给这个，不返回资源本体）
    public var resourceID: String?
    public var replyCount: Int
    /// 「回复 XXX：」的前半句
    public var repliedNickname: String?
    public var repliedContent: String?

    public init(id: String, content: String, time: Date, likedCount: Int = 0,
                resourceKind: ResourceKind = .song, resourceID: String? = nil,
                replyCount: Int = 0, repliedNickname: String? = nil,
                repliedContent: String? = nil) {
        self.id = id; self.content = content; self.time = time
        self.likedCount = likedCount; self.resourceKind = resourceKind
        self.resourceID = resourceID; self.replyCount = replyCount
        self.repliedNickname = repliedNickname; self.repliedContent = repliedContent
    }
}
