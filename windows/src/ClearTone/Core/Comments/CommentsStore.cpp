#include "Core/Comments/CommentsStore.h"

#include "Core/AsyncUtils.h"
#include "Core/Logging/CTLog.h"

#include <utility>

namespace ct {

namespace {

QString unknownUserMessage(const std::exception& error)
{
    return MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
}

} // namespace

CommentsStore::CommentsStore(ICommentProvider* provider) : m_provider(provider) {}

void CommentsStore::setSort(CommentSort value)
{
    if (m_sort == value) return;
    m_sort = value;
    notifyChanged();
}

Task<void> CommentsStore::loadAsync(
    Song song, std::optional<CommentSort> sort, CancellationToken ct)
{
    m_loadToken++;
    const int token = m_loadToken;
    if (m_cts) m_cts->cancel();
    m_cts = std::make_shared<LinkedCancellation>(ct, CancellationToken::none());
    const CancellationToken pageToken = m_cts->token();
    m_song = std::move(song);
    if (sort.has_value()) m_sort = *sort;
    m_loadedSort = m_sort;
    m_page = 1;
    m_cursor.reset();
    m_comments.clear();
    m_total = 0;
    m_hasMore = false;
    m_isLoadingMore = false;
    m_errorMessage.reset();
    m_paginationError.reset();
    m_likeError.reset();
    m_pendingLikeIDs.clear();
    m_likeTokens.clear();
    m_isLoading = true;
    notifyChanged();
    co_await fetchPageAsync(token, 1, true, pageToken);
    if (m_loadToken == token) {
        m_isLoading = false;
        notifyChanged();
    }
}

Task<void> CommentsStore::reloadAsync(CancellationToken ct)
{
    if (!m_song.has_value()) co_return;
    const Song song = *m_song;
    const CommentSort sort = m_sort;
    co_await loadAsync(song, sort, ct);
}

Task<void> CommentsStore::loadMoreAsync(CancellationToken ct)
{
    if (!m_hasMore || m_isLoadingMore || m_isLoading) co_return;
    m_isLoadingMore = true;
    m_paginationError.reset();
    const int token = m_loadToken;
    const int requestedPage = m_page + 1;
    auto linked = std::make_shared<LinkedCancellation>(
        m_cts ? m_cts->token() : CancellationToken::none(), ct);
    notifyChanged();
    co_await fetchPageAsync(token, requestedPage, false, linked->token());
    if (m_loadToken == token) {
        m_isLoadingMore = false;
        notifyChanged();
    }
}

Task<void> CommentsStore::fetchPageAsync(
    int token, int requestedPage, bool reset, CancellationToken ct)
{
    if (!m_song.has_value() || m_provider == nullptr) co_return;
    const QString songID = m_song->id;
    const CommentSort sort = m_loadedSort;
    const std::optional<QString> cursor = m_cursor;
    try {
        CommentPage result = co_await m_provider->fetchComments(
            songID, sort, requestedPage, pageSize, cursor, ct);
        if (m_loadToken != token || ct.isCancellationRequested()) co_return;
        QSet<QString> seen;
        if (!reset) {
            for (const Comment& comment : m_comments) seen.insert(comment.id);
        }
        QList<Comment> fresh;
        for (const Comment& comment : result.comments) {
            if (!seen.contains(comment.id)) {
                seen.insert(comment.id);
                fresh.append(comment);
            }
        }
        if (reset) {
            m_comments = std::move(fresh);
        } else {
            m_comments.append(fresh);
        }
        m_page = requestedPage;
        m_total = result.total;
        m_hasMore = result.hasMore && !result.comments.isEmpty()
            && (sort != CommentSort::Newest
                || (result.nextCursor.has_value() && result.nextCursor != cursor));
        m_cursor = result.nextCursor;
        notifyChanged();
    } catch (const MusicException& error) {
        if (m_loadToken != token || ct.isCancellationRequested()) co_return;
        if (reset) {
            m_errorMessage = error.userFacingMessage();
            m_comments.clear();
        } else {
            m_paginationError = error.userFacingMessage();
        }
        notifyChanged();
    } catch (const std::exception& error) {
        if (m_loadToken != token || ct.isCancellationRequested()) co_return;
        if (reset) {
            m_errorMessage = unknownUserMessage(error);
            m_comments.clear();
        } else {
            m_paginationError = unknownUserMessage(error);
        }
        notifyChanged();
    }
}

Task<void> CommentsStore::toggleLikeAsync(Comment comment, CancellationToken ct)
{
    if (!m_song.has_value() || m_pendingLikeIDs.contains(comment.id) || m_provider == nullptr) {
        co_return;
    }
    const int index = indexOfComment(comment.id);
    if (index < 0) co_return;
    const Song song = *m_song;
    const int token = m_loadToken;
    const int writeToken = ++m_likeTokenSeed;
    m_likeTokens.insert(comment.id, writeToken);
    m_pendingLikeIDs.insert(comment.id);
    m_likeError.reset();
    const Comment previous = m_comments.at(index);
    const bool target = !previous.isLiked;
    Comment updated = previous;
    updated.isLiked = target;
    updated.likedCount = qMax(0, previous.likedCount + (target ? 1 : -1));
    m_comments[index] = updated;
    notifyChanged();
    try {
        co_await m_provider->likeComment(song.id, comment.id, target, ct);
    } catch (const MusicException& error) {
        if (m_loadToken == token && m_likeTokens.value(comment.id) == writeToken) {
            const int currentIndex = indexOfComment(previous.id);
            if (currentIndex >= 0) {
                m_comments[currentIndex] = previous;
                notifyChanged();
                m_likeError = error.userFacingMessage();
                notifyChanged();
                CTLog::general().error(
                    QStringLiteral("评论点赞失败: %1").arg(CTLog::sanitize(error.message())));
            }
        }
    } catch (const std::exception& error) {
        if (m_loadToken == token && m_likeTokens.value(comment.id) == writeToken) {
            const int currentIndex = indexOfComment(previous.id);
            if (currentIndex >= 0) {
                m_comments[currentIndex] = previous;
                notifyChanged();
                m_likeError = unknownUserMessage(error);
                notifyChanged();
                CTLog::general().error(QStringLiteral("评论点赞失败: %1")
                                           .arg(CTLog::sanitize(QString::fromUtf8(error.what()))));
            }
        }
    }
    if (m_loadToken == token && m_likeTokens.value(comment.id) == writeToken) {
        m_likeTokens.remove(comment.id);
        m_pendingLikeIDs.remove(comment.id);
        notifyChanged();
    }
}

int CommentsStore::indexOfComment(const QString& commentID) const
{
    for (int index = 0; index < m_comments.size(); ++index) {
        if (m_comments.at(index).id == commentID) return index;
    }
    return -1;
}

void CommentsStore::notifyChanged()
{
    if (onChanged) onChanged();
}

} // namespace ct
