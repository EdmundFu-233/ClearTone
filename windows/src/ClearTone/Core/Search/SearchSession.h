#pragma once

#include "Core/Async.h"
#include "Core/Models/MusicProvider.h"

#include <functional>
#include <memory>
#include <optional>

namespace ct {

class SearchSession {
public:
    explicit SearchSession(IMusicProvider* provider = nullptr);

    std::function<void()> onChanged;

    const QString& draftQuery() const { return m_draftQuery; }
    void setDraftQuery(const QString& value);

    const std::optional<SearchResult>& result() const { return m_result; }
    bool isLoading() const { return m_isLoading; }
    const std::optional<QString>& errorMessage() const { return m_errorMessage; }
    bool isLoadingMore() const { return m_isLoadingMore; }
    const std::optional<QString>& paginationError() const { return m_paginationError; }
    const std::optional<QString>& activeQuery() const { return m_activeQuery; }
    const std::optional<SearchType>& activeType() const { return m_activeType; }
    int currentPage() const { return m_currentPage; }
    SearchType displayType() const { return m_activeType.value_or(SearchType::Song); }
    bool hasActiveQuery() const { return m_activeQuery.has_value(); }

    void submit(SearchType type);
    void retry(SearchType type);
    void refreshDataContext(SearchType type);
    void loadMore();
    void reset();
    void cancelInFlight();

private:
    static constexpr int pageSize = 30;

    void start(const QString& query, SearchType type);
    Task<void> searchPageAsync(
        QString query, SearchType type, int page, int generation, CancellationToken ct);
    Task<void> loadMorePageAsync(
        QString query, SearchType type, int page, int generation, CancellationToken ct);
    void notifyChanged();

    IMusicProvider* m_provider = nullptr;

    QString m_draftQuery;
    std::optional<SearchResult> m_result;
    bool m_isLoading = false;
    std::optional<QString> m_errorMessage;
    bool m_isLoadingMore = false;
    std::optional<QString> m_paginationError;
    std::optional<QString> m_activeQuery;
    std::optional<SearchType> m_activeType;
    int m_currentPage = 1;

    int m_generation = 0;
    std::shared_ptr<CancellationTokenSource> m_searchCts;
    std::shared_ptr<CancellationTokenSource> m_loadMoreCts;
};

} // namespace ct
