#include "Core/Search/SearchAssistStore.h"

#include "Core/AsyncUtils.h"
#include "Core/Models/MusicSocialProvider.h"
#include "Core/Persistence/PersistenceStore.h"

#include <QJsonArray>
#include <QJsonValue>

#include <utility>

namespace ct {

namespace {

class PersistenceStoreSearchAssistPersistence : public ISearchAssistPersistence {
public:
    QStringList loadHistory() override
    {
        const QJsonValue stored
            = PersistenceStore::shared().loadSetting(QStringLiteral("searchAssistHistory"));
        QStringList history;
        if (stored.isArray()) {
            for (const QJsonValue& item : stored.toArray()) {
                if (item.isString()) history.append(item.toString());
            }
        }
        return history;
    }

    void saveHistory(const QStringList& history) override
    {
        QJsonArray array;
        for (const QString& item : history) array.append(item);
        PersistenceStore::shared().saveSetting(QStringLiteral("searchAssistHistory"), array);
    }
};

} // namespace

SearchAssistStore::SearchAssistStore(ISearchAssistPersistence* persistence, IMusicSocialProvider* source)
    : m_source(source)
{
    if (persistence != nullptr) {
        m_persistence = persistence;
    } else {
        m_ownedPersistence = std::make_shared<PersistenceStoreSearchAssistPersistence>();
        m_persistence = m_ownedPersistence.get();
    }
    QStringList stored = m_persistence->loadHistory();
    if (stored.size() > historyLimit) stored = stored.mid(0, historyLimit);
    m_history = std::move(stored);
}

void SearchAssistStore::querySuggestions(const QString& keyword)
{
    if (m_debounceCts) m_debounceCts->cancel();
    m_debounceCts = nullptr;
    if (m_suggestionsCts) m_suggestionsCts->cancel();
    m_suggestionsCts = nullptr;
    const QString trimmed = keyword.trimmed();
    if (trimmed.isEmpty()) {
        m_suggestionToken++;
        m_suggestions.clear();
        m_isLoadingSuggestions = false;
        notifyChanged();
        return;
    }
    const int token = ++m_suggestionToken;
    auto cts = std::make_shared<CancellationTokenSource>();
    m_debounceCts = cts;
    startOnLoop(debouncedFetchAsync(trimmed, token, cts));
}

Task<void> SearchAssistStore::debouncedFetchAsync(
    QString keyword, int token, std::shared_ptr<CancellationTokenSource> cts)
{
    try {
        co_await Delay(debounceIntervalMs, cts->token());
    } catch (const MusicException& error) {
        if (error.isCancelled()) co_return;
        throw;
    }
    if (cts->isCancellationRequested()) co_return;
    co_await fetchSuggestionsAsync(keyword, token, std::move(cts));
}

Task<void> SearchAssistStore::fetchSuggestionsAsync(
    const QString& keyword, int token, std::shared_ptr<CancellationTokenSource> cts)
{
    if (token == m_suggestionToken) {
        m_suggestionsCts = cts;
        m_isLoadingSuggestions = true;
        notifyChanged();
    }
    if (m_source != nullptr) {
        try {
            QList<SearchSuggestion> loaded
                = co_await m_source->fetchSearchSuggestions(keyword, cts->token());
            if (token == m_suggestionToken && !cts->isCancellationRequested()) {
                m_suggestions = std::move(loaded);
                notifyChanged();
            }
        } catch (...) {
            if (token == m_suggestionToken) {
                m_suggestions.clear();
                notifyChanged();
            }
        }
    }
    if (m_suggestionsCts == cts) m_suggestionsCts = nullptr;
    if (token == m_suggestionToken) {
        m_isLoadingSuggestions = false;
        notifyChanged();
    }
}

void SearchAssistStore::clearSuggestions()
{
    if (m_debounceCts) m_debounceCts->cancel();
    m_debounceCts = nullptr;
    if (m_suggestionsCts) m_suggestionsCts->cancel();
    m_suggestionsCts = nullptr;
    m_suggestionToken++;
    m_suggestions.clear();
    m_isLoadingSuggestions = false;
    notifyChanged();
}

Task<void> SearchAssistStore::loadHotTermsAsync(CancellationToken ct)
{
    if (!m_hotTerms.isEmpty() || m_isLoadingHot) co_return;
    m_isLoadingHot = true;
    m_hotError.reset();
    notifyChanged();
    if (m_source != nullptr) {
        try {
            QList<HotSearchTerm> loaded = co_await m_source->fetchHotSearchTerms(ct);
            if (!ct.isCancellationRequested()) {
                m_hotTerms = std::move(loaded);
                notifyChanged();
            }
        } catch (const MusicException& error) {
            if (!error.isCancelled() && !ct.isCancellationRequested()) {
                m_hotError = error.userFacingMessage();
                notifyChanged();
            }
        } catch (const std::exception& error) {
            if (!ct.isCancellationRequested()) {
                m_hotError = MusicException::unknown(QString::fromUtf8(error.what()))
                                 .userFacingMessage();
                notifyChanged();
            }
        }
    }
    m_isLoadingHot = false;
    notifyChanged();
}

void SearchAssistStore::recordSearch(const QString& keyword)
{
    const QString trimmed = keyword.trimmed();
    if (trimmed.isEmpty()) return;
    for (int index = m_history.size() - 1; index >= 0; --index) {
        if (QString::compare(m_history.at(index), trimmed, Qt::CaseInsensitive) == 0) {
            m_history.removeAt(index);
        }
    }
    m_history.prepend(trimmed);
    if (m_history.size() > historyLimit) m_history = m_history.mid(0, historyLimit);
    notifyChanged();
    m_persistence->saveHistory(m_history);
}

void SearchAssistStore::removeHistory(const QString& keyword)
{
    for (int index = m_history.size() - 1; index >= 0; --index) {
        if (QString::compare(m_history.at(index), keyword, Qt::CaseInsensitive) == 0) {
            m_history.removeAt(index);
        }
    }
    notifyChanged();
    m_persistence->saveHistory(m_history);
}

void SearchAssistStore::clearHistory()
{
    m_history.clear();
    notifyChanged();
    m_persistence->saveHistory(m_history);
}

void SearchAssistStore::notifyChanged()
{
    if (onChanged) onChanged();
}

} // namespace ct
