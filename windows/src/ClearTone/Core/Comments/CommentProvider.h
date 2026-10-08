#pragma once

#include "Core/Async.h"
#include "Core/Models/SocialModels.h"

namespace ct {

class ICommentProvider {
public:
    virtual ~ICommentProvider() = default;

    virtual Task<CommentPage> fetchComments(const QString& songID, CommentSort sort, int page,
        int pageSize, const std::optional<QString>& cursor, CancellationToken ct) = 0;
    virtual Task<void> likeComment(
        const QString& songID, const QString& commentID, bool like, CancellationToken ct) = 0;
};

} // namespace ct
