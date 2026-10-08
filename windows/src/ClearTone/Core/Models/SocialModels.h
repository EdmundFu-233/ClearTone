#pragma once

#include <QDateTime>
#include <QList>
#include <QString>

#include <optional>

namespace ct {

enum class CommentSort {
    Recommended,
    Hot,
    Newest,
};

namespace commentSort {
int apiValue(CommentSort sort);
QString displayName(CommentSort sort);
} // namespace commentSort

struct Comment {
    QString id;
    QString content;
    QString userID;
    QString nickname;
    std::optional<QString> avatarURL;
    QDateTime time;
    int likedCount = 0;
    bool isLiked = false;
    int replyCount = 0;
    std::optional<QString> replyToNickname;
    std::optional<QString> replyToContent;
    bool isMine = false;

    bool operator==(const Comment&) const = default;
};

struct CommentPage {
    QList<Comment> comments;
    int total = 0;
    bool hasMore = false;
    std::optional<QString> nextCursor;
};

enum class UserNoticeKindType {
    Comment,
    Reply,
    Follow,
    Like,
    Unknown,
};

struct UserNoticeKind {
    UserNoticeKindType type = UserNoticeKindType::Unknown;
    int typeCode = 0;

    static UserNoticeKind fromTypeCode(int code);
    QString systemImage() const;
    QString label() const;

    bool operator==(const UserNoticeKind&) const = default;
};

struct UserNotice {
    QString id;
    UserNoticeKind kind;
    QDateTime time;
    std::optional<QString> actorNickname;
    std::optional<QString> actorAvatarURL;
    std::optional<QString> content;
    std::optional<QString> replyCommentText;
    std::optional<QString> relatedID;

    bool operator==(const UserNotice&) const = default;
};

struct PrivateConversation {
    QString id;
    QString userID;
    QString nickname;
    std::optional<QString> avatarURL;
    std::optional<QString> lastMessage;
    std::optional<QDateTime> lastTime;
    int unreadCount = 0;

    bool operator==(const PrivateConversation&) const = default;
};

enum class PrivateMessageKindType {
    Text,
    Image,
    Song,
    Album,
    Playlist,
    Unknown,
};

struct PrivateMessageKind {
    PrivateMessageKindType type = PrivateMessageKindType::Unknown;
    int msgType = 1;

    static PrivateMessageKind fromMsgType(int type);
    QString systemImage() const;
    QString label() const;

    bool operator==(const PrivateMessageKind&) const = default;
};

struct PrivateMessage {
    QString id;
    PrivateMessageKind kind;
    QString content;
    QDateTime time;
    bool isOutgoing = false;
    std::optional<QString> senderNickname;

    bool operator==(const PrivateMessage&) const = default;
};

enum class MyCommentResourceKind {
    Song = 0,
    Mv = 1,
    Playlist = 2,
    Album = 3,
    Radio = 4,
    Video = 5,
    Event = 6,
    Drama = 7,
};

namespace myCommentResourceKind {
QString label(MyCommentResourceKind kind);
bool isNavigable(MyCommentResourceKind kind);
} // namespace myCommentResourceKind

struct MyComment {
    QString id;
    QString content;
    QDateTime time;
    int likedCount = 0;
    MyCommentResourceKind resourceKind = MyCommentResourceKind::Song;
    std::optional<QString> resourceID;
    int replyCount = 0;
    std::optional<QString> repliedNickname;
    std::optional<QString> repliedContent;

    bool operator==(const MyComment&) const = default;
};

} // namespace ct
