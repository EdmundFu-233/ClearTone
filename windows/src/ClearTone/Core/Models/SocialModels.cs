namespace ClearTone.Core.Models;

public enum CommentSort
{
    Recommended,
    Hot,
    Newest,
}

public static class CommentSortExtensions
{
    public static int ApiValue(this CommentSort sort) => sort switch
    {
        CommentSort.Recommended => 99,
        CommentSort.Hot => 2,
        _ => 3,
    };

    public static string DisplayName(this CommentSort sort) => sort switch
    {
        CommentSort.Recommended => "推荐",
        CommentSort.Hot => "热度",
        _ => "最新",
    };
}

public record Comment
{
    public string Id { get; set; } = "";
    public string Content { get; set; } = "";
    public string UserID { get; set; } = "";
    public string Nickname { get; set; } = "";
    public string? AvatarURL { get; set; }
    public DateTimeOffset Time { get; set; } = DateTimeOffset.UtcNow;
    public int LikedCount { get; set; }
    public bool IsLiked { get; set; }
    public int ReplyCount { get; set; }
    public string? ReplyToNickname { get; set; }
    public string? ReplyToContent { get; set; }
    public bool IsMine { get; set; }
}

public record CommentPage
{
    public List<Comment> Comments { get; set; } = new();
    public int Total { get; set; }
    public bool HasMore { get; set; }
    public string? NextCursor { get; set; }
}

public abstract record UserNoticeKind
{
    public sealed record Comment : UserNoticeKind;
    public sealed record Reply : UserNoticeKind;
    public sealed record Follow : UserNoticeKind;
    public sealed record Like : UserNoticeKind;
    public sealed record Unknown(int TypeCode) : UserNoticeKind;

    public static UserNoticeKind FromTypeCode(int typeCode) => typeCode switch
    {
        1 => new Comment(),
        2 => new Reply(),
        3 => new Like(),
        4 => new Follow(),
        _ => new Unknown(typeCode),
    };

    public string SystemImage => this switch
    {
        Comment => "text.bubble",
        Reply => "arrowshape.turn.up.left",
        Follow => "person.badge.plus",
        Like => "hand.thumbsup",
        _ => "bell",
    };

    public string Label => this switch
    {
        Comment => "评论",
        Reply => "回复",
        Follow => "关注",
        Like => "赞",
        _ => "通知",
    };
}

public record UserNotice
{
    public string Id { get; set; } = "";
    public UserNoticeKind Kind { get; set; } = new UserNoticeKind.Unknown(0);
    public DateTimeOffset Time { get; set; } = DateTimeOffset.UtcNow;
    public string? ActorNickname { get; set; }
    public string? ActorAvatarURL { get; set; }
    public string? Content { get; set; }
    public string? ReplyCommentText { get; set; }
    public string? RelatedID { get; set; }
}

public record PrivateConversation
{
    public string Id { get; set; } = "";
    public string UserID { get; set; } = "";
    public string Nickname { get; set; } = "";
    public string? AvatarURL { get; set; }
    public string? LastMessage { get; set; }
    public DateTimeOffset? LastTime { get; set; }
    public int UnreadCount { get; set; }
}

public abstract record PrivateMessageKind
{
    public sealed record Text : PrivateMessageKind;
    public sealed record Image : PrivateMessageKind;
    public sealed record Song : PrivateMessageKind;
    public sealed record Album : PrivateMessageKind;
    public sealed record Playlist : PrivateMessageKind;
    public sealed record Unknown(int MsgType) : PrivateMessageKind;

    public static PrivateMessageKind FromMsgType(int msgType) => msgType switch
    {
        1 => new Text(),
        2 => new Image(),
        3 => new Song(),
        4 => new Album(),
        5 => new Playlist(),
        _ => new Unknown(msgType),
    };

    public string SystemImage => this switch
    {
        Text => "text.bubble",
        Image => "photo",
        Song => "music.note",
        Album => "square.stack",
        Playlist => "music.note.list",
        _ => "questionmark.bubble",
    };
}

public record PrivateMessage
{
    public string Id { get; set; } = "";
    public PrivateMessageKind Kind { get; set; } = new PrivateMessageKind.Unknown(1);
    public string Content { get; set; } = "";
    public DateTimeOffset Time { get; set; } = DateTimeOffset.UtcNow;
    public bool IsOutgoing { get; set; }
    public string? SenderNickname { get; set; }
}

public enum MyCommentResourceKind
{
    Song = 0,
    Mv = 1,
    Playlist = 2,
    Album = 3,
    Radio = 4,
    Video = 5,
    Event = 6,
    Drama = 7,
}

public static class MyCommentResourceKindExtensions
{
    public static string Label(this MyCommentResourceKind kind) => kind switch
    {
        MyCommentResourceKind.Song => "歌曲",
        MyCommentResourceKind.Mv => "MV",
        MyCommentResourceKind.Playlist => "歌单",
        MyCommentResourceKind.Album => "专辑",
        MyCommentResourceKind.Radio => "电台",
        MyCommentResourceKind.Video => "视频",
        MyCommentResourceKind.Event => "动态",
        _ => "广播剧",
    };

    public static bool IsNavigable(this MyCommentResourceKind kind) =>
        kind is MyCommentResourceKind.Song or MyCommentResourceKind.Playlist or MyCommentResourceKind.Album;
}

public record MyComment
{
    public string Id { get; set; } = "";
    public string Content { get; set; } = "";
    public DateTimeOffset Time { get; set; } = DateTimeOffset.UtcNow;
    public int LikedCount { get; set; }
    public MyCommentResourceKind ResourceKind { get; set; } = MyCommentResourceKind.Song;
    public string? ResourceID { get; set; }
    public int ReplyCount { get; set; }
    public string? RepliedNickname { get; set; }
    public string? RepliedContent { get; set; }
}
