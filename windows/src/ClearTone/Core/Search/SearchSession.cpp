#include "Core/Search/SearchSession.h"

#include "Core/AsyncUtils.h"

#include <utility>

namespace ct {

namespace {

std::optional<QString> userMessage(const std::exception& error)
{
    return MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
}

} // namespace

SearchSession::SearchSession(IMusicProvider* provider) : m_provider(provider) {}

void SearchSession::setDraftQuery(const QString& value)
{
    if (m_draftQuery == value) return;
    m_draftQuery = value;
    notifyChanged();
}

void SearchSession::submit(SearchType type)
{
    const QString query = m_draftQuery.trimmed();
    if (query.isEmpty()) return;
    start(query, type);
}

void SearchSession::retry(SearchType type)
{
    const std::optional<QString> query = m_activeQuery;
    if (!query.has_value()) {
        submit(type);
        return;
    }
    start(*query, m_activeType.value_or(type));
}

void SearchSession::refreshDataContext(SearchType type)
{
    const QString trimmed = m_draftQuery.trimmed();
    if (trimmed.isEmpty()) {
        if (!m_activeQuery.has_value()) return;
        start(*m_activeQuery, m_activeType.value_or(type));
        return;
    }
    submit(type);
}

void SearchSession::start(const QString& query, SearchType type)
{
    m_generation++;
    const int generation = m_generation;
    if (m_searchCts) m_searchCts->cancel();
    m_searchCts = std::make_shared<CancellationTokenSource>();
    const CancellationToken token = m_searchCts->token();
    if (m_loadMoreCts) m_loadMoreCts->cancel();
    m_loadMoreCts = nullptr;
    m_activeQuery = query;
    m_activeType = type;
    m_currentPage = 1;
    m_isLoading = true;
    m_errorMessage.reset();
    m_isLoadingMore = false;
    m_paginationError.reset();
    notifyChanged();
    startOnLoop(searchPageAsync(query, type, 1, generation, token));
}

Task<void> SearchSession::searchPageAsync(
    QString query, SearchType type, int page, int generation, CancellationToken ct)
{
    if (m_provider == nullptr) {
        if (generation == m_generation) {
            m_isLoading = false;
            notifyChanged();
        }
        co_return;
    }
    try {
        SearchResult found = co_await m_provider->search(query, type, page, pageSize, ct);
        if (generation == m_generation && !ct.isCancellationRequested()) {
            m_result = std::move(found);
            notifyChanged();
        }
    } catch (const MusicException& error) {
        if (generation == m_generation && !ct.isCancellationRequested()) {
            m_errorMessage = error.userFacingMessage();
            m_result.reset();
            notifyChanged();
        }
    } catch (const std::exception& error) {
        if (generation == m_generation && !ct.isCancellationRequested()) {
            m_errorMessage = userMessage(error);
            m_result.reset();
            notifyChanged();
        }
    }
    if (generation == m_generation) {
        m_isLoading = false;
        notifyChanged();
    }
}

void SearchSession::loadMore()
{
    if (!m_result.has_value() || !m_result->hasMore || m_isLoading || m_isLoadingMore) return;
    if (m_loadMoreCts) return;
    if (!m_activeQuery.has_value() || !m_activeType.has_value()) return;
    const int generation = m_generation;
    const int page = m_currentPage + 1;
    const QString query = *m_activeQuery;
    const SearchType type = *m_activeType;
    m_currentPage = page;
    m_isLoadingMore = true;
    m_paginationError.reset();
    m_loadMoreCts = std::make_shared<CancellationTokenSource>();
    const CancellationToken token = m_loadMoreCts->token();
    notifyChanged();
    startOnLoop(loadMorePageAsync(query, type, page, generation, token));
}

Task<void> SearchSession::loadMorePageAsync(
    QString query, SearchType type, int page, int generation, CancellationToken ct)
{
    if (m_provider == nullptr) {
        if (generation == m_generation) {
            m_loadMoreCts = nullptr;
            m_isLoadingMore = false;
            notifyChanged();
        }
        co_return;
    }
    try {
        SearchResult more = co_await m_provider->search(query, type, page, pageSize, ct);
        if (generation == m_generation && !ct.isCancellationRequested()) {
            SearchResult merged = m_result.value_or(SearchResult{});
            switch (type) {
            case SearchType::Song:
                merged.songs.append(more.songs);
                break;
            case SearchType::Artist:
                merged.artists.append(more.artists);
                break;
            case SearchType::Album:
                merged.albums.append(more.albums);
                break;
            case SearchType::Playlist:
                merged.playlists.append(more.playlists);
                break;
            }
            merged.totalCount = more.totalCount;
            merged.hasMore = more.hasMore;
            m_result = std::move(merged);
            notifyChanged();
        }
    } catch (const MusicException& error) {
        if (generation == m_generation && !ct.isCancellationRequested()) {
            m_currentPage = page - 1;
            m_paginationError = error.userFacingMessage();
            notifyChanged();
        }
    } catch (const std::exception& error) {
        if (generation == m_generation && !ct.isCancellationRequested()) {
            m_currentPage = page - 1;
            m_paginationError = userMessage(error);
            notifyChanged();
        }
    }
    if (generation == m_generation) {
        m_loadMoreCts = nullptr;
        m_isLoadingMore = false;
        notifyChanged();
    }
}

void SearchSession::reset()
{
    m_generation++;
    if (m_searchCts) m_searchCts->cancel();
    m_searchCts = nullptr;
    if (m_loadMoreCts) m_loadMoreCts->cancel();
    m_loadMoreCts = nullptr;
    m_activeQuery.reset();
    m_activeType.reset();
    m_result.reset();
    m_currentPage = 1;
    m_isLoading = false;
    m_isLoadingMore = false;
    m_errorMessage.reset();
    m_paginationError.reset();
    m_draftQuery.clear();
    notifyChanged();
}

void SearchSession::cancelInFlight()
{
    const bool hadInFlightPagination = m_loadMoreCts != nullptr;
    const bool hadInFlightSearch = m_isLoading;
    m_generation++;
    if (m_searchCts) m_searchCts->cancel();
    m_searchCts = nullptr;
    if (m_loadMoreCts) m_loadMoreCts->cancel();
    m_loadMoreCts = nullptr;
    if (hadInFlightSearch) {
        m_activeQuery.reset();
        m_activeType.reset();
        m_result.reset();
        m_currentPage = 1;
        m_errorMessage.reset();
        m_paginationError.reset();
    }
    if (hadInFlightPagination) m_currentPage = qMax(1, m_currentPage - 1);
    m_isLoading = false;
    m_isLoadingMore = false;
    notifyChanged();
}

void SearchSession::notifyChanged()
{
    if (onChanged) onChanged();
}

} // namespace ct
