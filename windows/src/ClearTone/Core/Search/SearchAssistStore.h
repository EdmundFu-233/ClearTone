#pragma once

#include "Core/Async.h"
#include "Core/Models/DiscoveryModels.h"

#include <QStringList>

#include <functional>
#include <memory>
#include <optional>

namespace ct {

class IMusicSocialProvider;

class ISearchAssistPersistence {
public:
    virtual ~ISearchAssistPersistence() = default;

    virtual QStringList loadHistory() = 0;
    virtual void saveHistory(const QStringList& history) = 0;
};

class SearchAssistStore {
public:
    explicit SearchAssistStore(
        ISearchAssistPersistence* persistence = nullptr, IMusicSocialProvider* source = nullptr);

    std::function<void()> onChanged;

    const QList<SearchSuggestion>& suggestions() const { return m_suggestions; }
    bool isLoadingSuggestions() const { return m_isLoadingSuggestions; }
    const QList<HotSearchTerm>& hotTerms() const { return m_hotTerms; }
    bool isLoadingHot() const { return m_isLoadingHot; }
    const std::optional<QString>& hotError() const { return m_hotError; }
    const QStringList& history() const { return m_history; }

    void querySuggestions(const QString& keyword);
    void clearSuggestions();
    Task<void> loadHotTermsAsync(CancellationToken ct = CancellationToken::none());
    void recordSearch(const QString& keyword);
    void removeHistory(const QString& keyword);
    void clearHistory();

private:
    static constexpr int debounceIntervalMs = 250;
    static constexpr int historyLimit = 20;

    Task<void> debouncedFetchAsync(
        QString keyword, int token, std::shared_ptr<CancellationTokenSource> cts);
    Task<void> fetchSuggestionsAsync(
        const QString& keyword, int token, std::shared_ptr<CancellationTokenSource> cts);
    void notifyChanged();

    IMusicSocialProvider* m_source = nullptr;
    std::shared_ptr<ISearchAssistPersistence> m_ownedPersistence;
    ISearchAssistPersistence* m_persistence = nullptr;

    QList<SearchSuggestion> m_suggestions;
    bool m_isLoadingSuggestions = false;
    QList<HotSearchTerm> m_hotTerms;
    bool m_isLoadingHot = false;
    std::optional<QString> m_hotError;
    QStringList m_history;

    int m_suggestionToken = 0;
    std::shared_ptr<CancellationTokenSource> m_debounceCts;
    std::shared_ptr<CancellationTokenSource> m_suggestionsCts;
};

} // namespace ct
