#include "Core/Models/SocialModels.h"

namespace ct {

namespace commentSort {

int apiValue(CommentSort sort)
{
    switch (sort) {
    case CommentSort::Recommended:
        return 99;
    case CommentSort::Hot:
        return 2;
    case CommentSort::Newest:
        return 3;
    }
    return 3;
}

QString displayName(CommentSort sort)
{
    switch (sort) {
    case CommentSort::Recommended:
        return QStringLiteral("推荐");
    case CommentSort::Hot:
        return QStringLiteral("热度");
    case CommentSort::Newest:
        return QStringLiteral("最新");
    }
    return QStringLiteral("最新");
}

} // namespace commentSort

UserNoticeKind UserNoticeKind::fromTypeCode(int code)
{
    switch (code) {
    case 1:
        return {UserNoticeKindType::Comment, code};
    case 2:
        return {UserNoticeKindType::Reply, code};
    case 3:
        return {UserNoticeKindType::Like, code};
    case 4:
        return {UserNoticeKindType::Follow, code};
    default:
        return {UserNoticeKindType::Unknown, code};
    }
}

QString UserNoticeKind::systemImage() const
{
    switch (type) {
    case UserNoticeKindType::Comment:
        return QStringLiteral("text.bubble");
    case UserNoticeKindType::Reply:
        return QStringLiteral("arrowshape.turn.up.left");
    case UserNoticeKindType::Follow:
        return QStringLiteral("person.badge.plus");
    case UserNoticeKindType::Like:
        return QStringLiteral("hand.thumbsup");
    case UserNoticeKindType::Unknown:
        return QStringLiteral("bell");
    }
    return QStringLiteral("bell");
}

QString UserNoticeKind::label() const
{
    switch (type) {
    case UserNoticeKindType::Comment:
        return QStringLiteral("评论");
    case UserNoticeKindType::Reply:
        return QStringLiteral("回复");
    case UserNoticeKindType::Follow:
        return QStringLiteral("关注");
    case UserNoticeKindType::Like:
        return QStringLiteral("赞");
    case UserNoticeKindType::Unknown:
        return QStringLiteral("通知");
    }
    return QStringLiteral("通知");
}

PrivateMessageKind PrivateMessageKind::fromMsgType(int type)
{
    switch (type) {
    case 1:
        return {PrivateMessageKindType::Text, type};
    case 2:
        return {PrivateMessageKindType::Image, type};
    case 3:
        return {PrivateMessageKindType::Song, type};
    case 4:
        return {PrivateMessageKindType::Album, type};
    case 5:
        return {PrivateMessageKindType::Playlist, type};
    default:
        return {PrivateMessageKindType::Unknown, type};
    }
}

QString PrivateMessageKind::systemImage() const
{
    switch (type) {
    case PrivateMessageKindType::Text:
        return QStringLiteral("text.bubble");
    case PrivateMessageKindType::Image:
        return QStringLiteral("photo");
    case PrivateMessageKindType::Song:
        return QStringLiteral("music.note");
    case PrivateMessageKindType::Album:
        return QStringLiteral("square.stack");
    case PrivateMessageKindType::Playlist:
        return QStringLiteral("music.note.list");
    case PrivateMessageKindType::Unknown:
        return QStringLiteral("questionmark.bubble");
    }
    return QStringLiteral("questionmark.bubble");
}

QString PrivateMessageKind::label() const
{
    switch (type) {
    case PrivateMessageKindType::Text:
        return QStringLiteral("文本");
    case PrivateMessageKindType::Image:
        return QStringLiteral("图片");
    case PrivateMessageKindType::Song:
        return QStringLiteral("歌曲");
    case PrivateMessageKindType::Album:
        return QStringLiteral("专辑");
    case PrivateMessageKindType::Playlist:
        return QStringLiteral("歌单");
    case PrivateMessageKindType::Unknown:
        return QStringLiteral("消息");
    }
    return QStringLiteral("消息");
}

namespace myCommentResourceKind {

QString label(MyCommentResourceKind kind)
{
    switch (kind) {
    case MyCommentResourceKind::Song:
        return QStringLiteral("歌曲");
    case MyCommentResourceKind::Mv:
        return QStringLiteral("MV");
    case MyCommentResourceKind::Playlist:
        return QStringLiteral("歌单");
    case MyCommentResourceKind::Album:
        return QStringLiteral("专辑");
    case MyCommentResourceKind::Radio:
        return QStringLiteral("电台");
    case MyCommentResourceKind::Video:
        return QStringLiteral("视频");
    case MyCommentResourceKind::Event:
        return QStringLiteral("动态");
    case MyCommentResourceKind::Drama:
        return QStringLiteral("广播剧");
    }
    return QStringLiteral("歌曲");
}

bool isNavigable(MyCommentResourceKind kind)
{
    return kind == MyCommentResourceKind::Song || kind == MyCommentResourceKind::Playlist
        || kind == MyCommentResourceKind::Album;
}

} // namespace myCommentResourceKind

} // namespace ct
