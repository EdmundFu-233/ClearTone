using ClearTone.Core.Models;

namespace ClearTone.Core.Comments;

public interface ICommentProvider
{
    Task<CommentPage> FetchCommentsAsync(
        string songID,
        CommentSort sort,
        int page,
        int pageSize = 20,
        string? cursor = null,
        CancellationToken ct = default);

    Task LikeCommentAsync(string songID, string commentID, bool like, CancellationToken ct = default);
}
