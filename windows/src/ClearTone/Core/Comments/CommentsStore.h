#pragma once

#include "Core/Async.h"
#include "Core/AsyncUtils.h"
#include "Core/Comments/CommentProvider.h"
#include "Core/Models/MusicModels.h"
#include "Core/Models/SocialModels.h"

#include <QHash>
#include <QSet>
#include <QString>

#include <functional>
#include <memory>
#include <optional>

namespace ct {

class CommentsStore {
public:
    explicit CommentsStore(ICommentProvider* provider = nullptr);

    std::function<void()> onChanged;

    const QList<Comment>& comments() const { return m_comments; }
    int total() const { return m_total; }
    bool hasMore() const { return m_hasMore; }
    bool isLoading() const { return m_isLoading; }
    bool isLoadingMore() const { return m_isLoadingMore; }
    const std::optional<QString>& errorMessage() const { return m_errorMessage; }
    const std::optional<QString>& paginationError() const { return m_paginationError; }
    const std::optional<QString>& likeError() const { return m_likeError; }
    QSet<QString> pendingLikeIDs() const { return m_pendingLikeIDs; }
    CommentSort sort() const { return m_sort; }
    void setSort(CommentSort value);
    const std::optional<Song>& song() const { return m_song; }

    Task<void> loadAsync(Song song, std::optional<CommentSort> sort = std::nullopt,
        CancellationToken ct = CancellationToken::none());
    Task<void> reloadAsync(CancellationToken ct = CancellationToken::none());
    Task<void> loadMoreAsync(CancellationToken ct = CancellationToken::none());
    Task<void> toggleLikeAsync(Comment comment, CancellationToken ct = CancellationToken::none());

private:
    static constexpr int pageSize = 20;

    Task<void> fetchPageAsync(int token, int requestedPage, bool reset, CancellationToken ct);
    int indexOfComment(const QString& commentID) const;
    void notifyChanged();

    ICommentProvider* m_provider = nullptr;

    QList<Comment> m_comments;
    int m_total = 0;
    bool m_hasMore = false;
    bool m_isLoading = false;
    bool m_isLoadingMore = false;
    std::optional<QString> m_errorMessage;
    std::optional<QString> m_paginationError;
    std::optional<QString> m_likeError;
    QSet<QString> m_pendingLikeIDs;
    CommentSort m_sort = CommentSort::Recommended;
    std::optional<Song> m_song;

    int m_loadToken = 0;
    int m_page = 1;
    std::optional<QString> m_cursor;
    CommentSort m_loadedSort = CommentSort::Recommended;
    QHash<QString, int> m_likeTokens;
    int m_likeTokenSeed = 0;
    std::shared_ptr<LinkedCancellation> m_cts;
};

} // namespace ct
