#pragma once

#include "Core/Async.h"
#include "Core/Models/DiscoveryModels.h"
#include "Core/Models/MusicProvider.h"
#include "Core/Search/SearchAssistStore.h"
#include "Core/Search/SearchSession.h"

#include <QMetaObject>
#include <QString>
#include <QWidget>

#include <memory>
#include <optional>

class QHBoxLayout;
class QLineEdit;
class QPushButton;
class QScrollBar;
class QVBoxLayout;

namespace ct {

class SearchView : public QWidget {
    Q_OBJECT

public:
    explicit SearchView(QWidget* parent = nullptr);
    ~SearchView() override;

protected:
    void showEvent(QShowEvent* event) override;
    void hideEvent(QHideEvent* event) override;

private:
    void render();
    void renderAssist();
    void renderTypePicker();
    void scheduleRender();
    void scheduleAssist();
    void scheduleAppChange();
    void handleAppChange();

    void submit();
    void clearSearch();
    void switchType(SearchType type);
    void closeAssist();
    void pickTerm(const QString& term);
    void pickSuggestion(const SearchSuggestion& suggestion);
    void syncDraft(const QString& text);
    void applyExternalQuery(const QString& query);

    QWidget* buildResults();
    QWidget* buildResultList(const SearchResult& result, SearchType type);
    QWidget* buildFooter();
    QWidget* buildSuggestions();
    QWidget* buildSuggestionRow(const SearchSuggestion& suggestion);
    QWidget* buildHistory();
    QWidget* buildHotTerms();
    QString resultKey() const;
    void hookScrollbar(QScrollBar* bar);
    void onResultScroll();

    SearchSession m_session;
    SearchAssistStore m_assist;

    QLineEdit* m_searchBox = nullptr;
    QPushButton* m_clearButton = nullptr;
    QWidget* m_typePicker = nullptr;
    QHBoxLayout* m_typePickerLayout = nullptr;
    QWidget* m_assistHost = nullptr;
    QVBoxLayout* m_assistLayout = nullptr;
    QWidget* m_resultHost = nullptr;
    QVBoxLayout* m_resultLayout = nullptr;
    QWidget* m_footerHost = nullptr;
    QVBoxLayout* m_footerLayout = nullptr;

    SearchType m_searchType = SearchType::Song;
    bool m_assistOpen = false;
    bool m_suppressTextChange = false;
    bool m_pendingScrollToEnd = false;
    bool m_hasRendered = false;
    bool m_renderScheduled = false;
    bool m_assistScheduled = false;
    bool m_appChangeScheduled = false;

    QString m_lastDataContextKey;
    QString m_lastExternalQuery;
    QString m_renderedResultKey;
    bool m_renderedLoading = false;
    std::optional<QString> m_renderedError;
    SearchType m_renderedType = SearchType::Song;

    QMetaObject::Connection m_scrollConnection;
    QScrollBar* m_scrollBar = nullptr;

    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    int m_appObserver = 0;
    int m_contextObserver = 0;
};

} // namespace ct
