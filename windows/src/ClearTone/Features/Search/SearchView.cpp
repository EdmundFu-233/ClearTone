#include "Features/Search/SearchView.h"

#include "App/AppState.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/L10n.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Providers/Netease/NeteaseProvider.h"
#include "Providers/Netease/NeteaseSocialProvider.h"

#include <QFrame>
#include "DesignSystem/FlowLayout.h"
#include <QHBoxLayout>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QPalette>
#include <QProgressBar>
#include <QPushButton>
#include <QScrollArea>
#include <QScrollBar>
#include <QTimer>
#include <QVBoxLayout>

#include <utility>

namespace ct {

namespace {

IMusicSocialProvider& socialProvider()
{
    auto* session = AppState::shared().social();
    if (auto* social = dynamic_cast<IMusicSocialProvider*>(session)) return *social;
    return NeteaseSocialProvider::shared();
}

void clearLayout(QLayout* layout)
{
    while (QLayoutItem* item = layout->takeAt(0)) {
        if (QWidget* widget = item->widget()) widget->deleteLater();
        if (QLayout* child = item->layout()) {
            clearLayout(child);
            child->deleteLater();
        }
        delete item;
    }
}

void setHost(QVBoxLayout* layout, QWidget* content, bool stretch = false)
{
    while (QLayoutItem* item = layout->takeAt(0)) {
        if (QWidget* widget = item->widget()) {
            if (widget != content) widget->deleteLater();
        }
        delete item;
    }
    if (content == nullptr) return;
    if (stretch) {
        layout->addWidget(content, 1);
    } else {
        layout->addWidget(content);
    }
}

class SearchLineEdit : public QLineEdit {
public:
    using QLineEdit::QLineEdit;

    std::function<void()> onFocus;
    std::function<void()> onSubmit;
    std::function<void()> onEscape;

protected:
    void focusInEvent(QFocusEvent* event) override
    {
        QLineEdit::focusInEvent(event);
        if (onFocus) onFocus();
    }

    void keyPressEvent(QKeyEvent* event) override
    {
        if (event->key() == Qt::Key_Return || event->key() == Qt::Key_Enter) {
            event->accept();
            if (onSubmit) onSubmit();
            return;
        }
        if (event->key() == Qt::Key_Escape) {
            event->accept();
            if (onEscape) onEscape();
            return;
        }
        QLineEdit::keyPressEvent(event);
    }
};

QWidget* sectionMessage(const QString& text)
{
    auto* label = ui::secondaryLabel(text);
    label->setContentsMargins(CTSpacing::Lg, CTSpacing::Sm, CTSpacing::Lg, CTSpacing::Md);
    return label;
}

QWidget* divider()
{
    auto* wrap = new QWidget();
    auto* layout = new QVBoxLayout(wrap);
    layout->setContentsMargins(CTSpacing::Lg, CTSpacing::Sm, CTSpacing::Lg, CTSpacing::Sm);
    layout->addWidget(ui::separator());
    return wrap;
}

QString kindGlyph(SearchSuggestion::Kind kind)
{
    switch (kind) {
    case SearchSuggestion::Kind::Song:
        return QStringLiteral("♪");
    case SearchSuggestion::Kind::Artist:
        return QStringLiteral("☺");
    case SearchSuggestion::Kind::Album:
        return QStringLiteral("▣");
    case SearchSuggestion::Kind::Playlist:
        return QStringLiteral("≡");
    }
    return QStringLiteral("♪");
}

QString kindLabel(SearchSuggestion::Kind kind)
{
    switch (kind) {
    case SearchSuggestion::Kind::Song:
        return QStringLiteral("单曲");
    case SearchSuggestion::Kind::Artist:
        return QStringLiteral("歌手");
    case SearchSuggestion::Kind::Album:
        return QStringLiteral("专辑");
    case SearchSuggestion::Kind::Playlist:
        return QStringLiteral("歌单");
    }
    return QStringLiteral("单曲");
}

} // namespace

SearchView::SearchView(QWidget* parent)
    : QWidget(parent)
    , m_session(AppState::shared().provider())
    , m_assist(nullptr, &socialProvider())
{
    setObjectName(QStringLiteral("ctSearchView"));
    setStyleSheet(QStringLiteral("QWidget#ctSearchView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    auto* searchBar = new QFrame(this);
    searchBar->setObjectName(QStringLiteral("ctSearchBar"));
    searchBar->setStyleSheet(
        QStringLiteral("QFrame#ctSearchBar { background: %1; border-radius: %2px; }")
            .arg(CTColors::panel().name())
            .arg(CTRadius::Medium));

    auto* searchBarLayout = new QHBoxLayout(searchBar);
    searchBarLayout->setContentsMargins(CTSpacing::Md, CTSpacing::Md, CTSpacing::Md, CTSpacing::Md);
    searchBarLayout->setSpacing(CTSpacing::Sm);

    auto* searchBox = new SearchLineEdit(searchBar);
    m_searchBox = searchBox;
    m_searchBox->setPlaceholderText(QStringLiteral("搜索歌曲、歌手、专辑、歌单"));
    m_searchBox->setFrame(false);
    m_searchBox->setStyleSheet(QStringLiteral("QLineEdit { background: transparent; border: none; color: %1; }")
                                   .arg(CTColors::textPrimary().name()));
    searchBox->onFocus = [this] {
        m_assistOpen = true;
        detach(m_assist.loadHotTermsAsync());
        renderAssist();
    };
    searchBox->onSubmit = [this] { submit(); };
    searchBox->onEscape = [this] { closeAssist(); };
    connect(m_searchBox, &QLineEdit::textChanged, this, [this](const QString& text) {
        if (m_suppressTextChange) return;
        m_session.setDraftQuery(text);
        m_clearButton->setVisible(!text.isEmpty());
        if (!m_searchBox->hasFocus()) return;
        m_assistOpen = true;
        m_assist.querySuggestions(text);
        renderAssist();
    });
    searchBarLayout->addWidget(m_searchBox, 1);

    m_clearButton = new QPushButton(QStringLiteral("✕"), searchBar);
    m_clearButton->setFlat(true);
    m_clearButton->setCursor(Qt::PointingHandCursor);
    m_clearButton->setFixedWidth(24);
    m_clearButton->setStyleSheet(QStringLiteral(
        "QPushButton { background: transparent; border: none; color: %1; font-size: 12px; }")
                                     .arg(CTColors::textSecondary().name()));
    m_clearButton->setVisible(false);
    connect(m_clearButton, &QPushButton::clicked, this, [this] { clearSearch(); });
    searchBarLayout->addWidget(m_clearButton, 0, Qt::AlignVCenter);

    auto* searchWrap = new QWidget(this);
    auto* searchWrapLayout = new QVBoxLayout(searchWrap);
    searchWrapLayout->setContentsMargins(CTSpacing::Lg, CTSpacing::Lg, CTSpacing::Lg, 0);
    searchWrapLayout->addWidget(searchBar);
    root->addWidget(searchWrap);

    auto* assistScroll = new QScrollArea(this);
    assistScroll->setWidgetResizable(true);
    assistScroll->setFrameShape(QFrame::NoFrame);
    assistScroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    assistScroll->setMinimumHeight(140);
    assistScroll->setMaximumHeight(220);
    m_assistHost = assistScroll;
    auto* assistContent = new QWidget();
    assistScroll->setWidget(assistContent);
    assistContent->setAutoFillBackground(false);
    m_assistLayout = new QVBoxLayout(assistContent);
    m_assistLayout->setContentsMargins(CTSpacing::Lg, CTSpacing::Xs, CTSpacing::Lg, 0);
    m_assistLayout->setSpacing(0);
    m_assistHost->setVisible(false);
    root->addWidget(m_assistHost);

    m_typePicker = new QWidget(this);
    m_typePickerLayout = new QHBoxLayout(m_typePicker);
    m_typePickerLayout->setContentsMargins(CTSpacing::Lg, CTSpacing::Md, CTSpacing::Lg, CTSpacing::Md);
    m_typePickerLayout->setSpacing(CTSpacing::Sm);
    renderTypePicker();
    root->addWidget(m_typePicker);

    m_resultHost = new QWidget(this);
    m_resultLayout = new QVBoxLayout(m_resultHost);
    m_resultLayout->setContentsMargins(0, 0, 0, 0);
    m_resultLayout->setSpacing(0);
    root->addWidget(m_resultHost, 1);

    m_footerHost = new QWidget(this);
    m_footerLayout = new QVBoxLayout(m_footerHost);
    m_footerLayout->setContentsMargins(0, 0, 0, 0);
    m_footerLayout->setSpacing(0);
    root->addWidget(m_footerHost);

    m_lastDataContextKey = AppState::shared().dataContextKey();
    m_lastExternalQuery = AppState::shared().searchQuery();
    m_appObserver = AppState::shared().changed.subscribe([this] { scheduleAppChange(); });
    m_contextObserver = AppState::shared().dataContextChanged.subscribe([this] { scheduleAppChange(); });
    m_session.onChanged = [this] { scheduleRender(); };
    m_assist.onChanged = [this] { scheduleAssist(); };

    render();
    renderAssist();
    detach(m_assist.loadHotTermsAsync());
}

SearchView::~SearchView()
{
    *m_alive = false;
    m_session.onChanged = nullptr;
    m_assist.onChanged = nullptr;
    AppState::shared().changed.unsubscribe(m_appObserver);
    AppState::shared().dataContextChanged.unsubscribe(m_contextObserver);
    if (m_scrollConnection) QObject::disconnect(m_scrollConnection);
}

void SearchView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    applyExternalQuery(AppState::shared().searchQuery());
}

void SearchView::hideEvent(QHideEvent* event)
{
    QWidget::hideEvent(event);
    m_session.cancelInFlight();
    render();
}

void SearchView::scheduleRender()
{
    if (m_renderScheduled) return;
    m_renderScheduled = true;
    QMetaObject::invokeMethod(
        this,
        [this] {
            m_renderScheduled = false;
            render();
        },
        Qt::QueuedConnection);
}

void SearchView::scheduleAssist()
{
    if (m_assistScheduled) return;
    m_assistScheduled = true;
    QMetaObject::invokeMethod(
        this,
        [this] {
            m_assistScheduled = false;
            renderAssist();
        },
        Qt::QueuedConnection);
}

void SearchView::scheduleAppChange()
{
    if (m_appChangeScheduled) return;
    m_appChangeScheduled = true;
    QMetaObject::invokeMethod(
        this,
        [this] {
            m_appChangeScheduled = false;
            handleAppChange();
        },
        Qt::QueuedConnection);
}

void SearchView::handleAppChange()
{
    const AppState& app = AppState::shared();
    const QString key = app.dataContextKey();
    const QString external = app.searchQuery();
    const bool contextChanged = key != m_lastDataContextKey;
    const bool queryChanged = external != m_lastExternalQuery;
    if (!contextChanged && !queryChanged) return;
    m_lastDataContextKey = key;
    m_lastExternalQuery = external;
    if (contextChanged) {
        m_session.refreshDataContext(m_searchType);
        render();
    }
    if (queryChanged) applyExternalQuery(external);
}

void SearchView::applyExternalQuery(const QString& query)
{
    const QString incoming = query.trimmed();
    if (incoming.isEmpty()) return;
    if (m_session.activeQuery() == incoming) {
        syncDraft(incoming);
        return;
    }
    syncDraft(incoming);
    submit();
}

void SearchView::submit()
{
    const QString keyword = m_searchBox->text().trimmed();
    if (keyword.isEmpty()) return;
    m_session.setDraftQuery(keyword);
    m_assist.recordSearch(keyword);
    if (AppState::shared().searchQuery() != keyword) AppState::shared().setSearchQuery(keyword);
    closeAssist();
    m_pendingScrollToEnd = false;
    m_session.submit(m_searchType);
    render();
}

void SearchView::clearSearch()
{
    m_suppressTextChange = true;
    m_searchBox->setText(QString());
    m_suppressTextChange = false;
    m_clearButton->setVisible(false);
    m_session.reset();
    m_assist.clearSuggestions();
    closeAssist();
    render();
}

void SearchView::switchType(SearchType type)
{
    if (m_searchType == type) return;
    m_searchType = type;
    renderTypePicker();
    closeAssist();
    if (m_searchBox->text().trimmed().isEmpty()) {
        m_session.reset();
        render();
    } else {
        submit();
    }
}

void SearchView::closeAssist()
{
    m_assistOpen = false;
    renderAssist();
}

void SearchView::syncDraft(const QString& text)
{
    m_suppressTextChange = true;
    m_searchBox->setText(text);
    m_suppressTextChange = false;
    m_clearButton->setVisible(!text.isEmpty());
    m_session.setDraftQuery(text);
}

void SearchView::pickTerm(const QString& term)
{
    syncDraft(term);
    closeAssist();
    submit();
}

void SearchView::pickSuggestion(const SearchSuggestion& suggestion)
{
    closeAssist();
    switch (suggestion.suggestionKind) {
    case SearchSuggestion::Kind::Song:
        m_searchType = SearchType::Song;
        renderTypePicker();
        syncDraft(suggestion.title);
        submit();
        break;
    case SearchSuggestion::Kind::Artist:
        AppState::shared().openArtist(suggestion.targetID);
        break;
    case SearchSuggestion::Kind::Album:
        AppState::shared().openAlbum(suggestion.targetID);
        break;
    case SearchSuggestion::Kind::Playlist:
        AppState::shared().openPlaylist(suggestion.targetID);
        break;
    }
}

void SearchView::renderTypePicker()
{
    clearLayout(m_typePickerLayout);
    for (SearchType type : searchType::all()) {
        auto* button = type == m_searchType ? ui::accentButton(searchType::displayName(type))
                                            : ui::ghostButton(searchType::displayName(type));
        connect(button, &QPushButton::clicked, this, [this, type] { switchType(type); });
        m_typePickerLayout->addWidget(button);
    }
    m_typePickerLayout->addStretch(1);
}

void SearchView::render()
{
    const bool loading = m_session.isLoading();
    const std::optional<QString>& error = m_session.errorMessage();
    const SearchType type = m_session.displayType();
    const QString key = resultKey();

    if (!m_hasRendered || key != m_renderedResultKey || loading != m_renderedLoading
        || error != m_renderedError || type != m_renderedType) {
        m_hasRendered = true;
        m_renderedResultKey = key;
        m_renderedLoading = loading;
        m_renderedError = error;
        m_renderedType = type;
        hookScrollbar(nullptr);
        setHost(m_resultLayout, buildResults(), true);
        if (m_pendingScrollToEnd) {
            m_pendingScrollToEnd = false;
            QTimer::singleShot(0, this, [this] {
                if (m_scrollBar != nullptr) m_scrollBar->setValue(m_scrollBar->maximum());
            });
        }
    }
    setHost(m_footerLayout, buildFooter());
}

QString SearchView::resultKey() const
{
    const std::optional<SearchResult>& result = m_session.result();
    if (!result.has_value()) return QStringLiteral("none");
    return QStringLiteral("%1|%2|%3|%4|%5|%6|%7|%8")
        .arg(m_session.activeQuery().value_or(QString()))
        .arg(static_cast<int>(m_session.displayType()))
        .arg(result->songs.size())
        .arg(result->artists.size())
        .arg(result->albums.size())
        .arg(result->playlists.size())
        .arg(result->hasMore ? 1 : 0)
        .arg(m_session.currentPage());
}

QWidget* SearchView::buildResults()
{
    if (m_session.isLoading()) {
        return ui::statusPanel(QStringLiteral("加载中…"), true);
    }
    if (m_session.errorMessage().has_value()) {
        return ui::errorPanel(*m_session.errorMessage(), [this] { m_session.retry(m_searchType); });
    }
    if (!m_session.result().has_value()) {
        return ui::statusPanel(QStringLiteral("搜索音乐"), false);
    }
    const SearchResult& result = *m_session.result();
    if (result.isEmpty()) {
        return ui::statusPanel(QStringLiteral("没有找到相关结果"), false);
    }
    return buildResultList(result, m_session.displayType());
}

QWidget* SearchView::buildResultList(const SearchResult& result, SearchType type)
{
    if (type == SearchType::Song) {
        auto* list = new SongListView();
        list->setSongs(result.songs);
        hookScrollbar(list->listWidget()->verticalScrollBar());
        return list;
    }

    QList<QWidget*> cards;
    switch (type) {
    case SearchType::Artist:
        for (const Artist& artist : result.artists) {
            cards.append(ui::artistCard(artist, [](const Artist& item) {
                AppState::shared().openArtist(item.id);
            }));
        }
        break;
    case SearchType::Album:
        for (const Album& album : result.albums) {
            cards.append(ui::albumCard(album, [](const Album& item) {
                AppState::shared().openAlbum(item.id);
            }));
        }
        break;
    case SearchType::Playlist:
        for (const Playlist& playlist : result.playlists) {
            cards.append(ui::playlistCard(playlist, [](const Playlist& item) {
                AppState::shared().openPlaylist(item.id);
            }));
        }
        break;
    case SearchType::Song:
        break;
    }

    auto* container = ui::cardGrid(cards);
    container->layout()->setContentsMargins(CTSpacing::Xl, CTSpacing::Md, CTSpacing::Xl, CTSpacing::Xl);

    auto* area = ui::scrollWrapper(container);
    hookScrollbar(area->verticalScrollBar());
    return area;
}

QWidget* SearchView::buildFooter()
{
    auto* panel = new QWidget();
    auto* layout = new QHBoxLayout(panel);
    layout->setContentsMargins(0, CTSpacing::Sm, 0, CTSpacing::Md);
    layout->setSpacing(CTSpacing::Sm);
    layout->setAlignment(Qt::AlignCenter);

    if (m_session.isLoadingMore()) {
        auto* progress = new QProgressBar(panel);
        progress->setRange(0, 0);
        progress->setTextVisible(false);
        progress->setFixedWidth(120);
        progress->setFixedHeight(4);
        layout->addWidget(progress, 0, Qt::AlignVCenter);
        layout->addWidget(ui::secondaryLabel(QStringLiteral("加载中…")), 0, Qt::AlignVCenter);
        return panel;
    }
    if (m_session.paginationError().has_value()) {
        auto* error = ui::secondaryLabel(*m_session.paginationError());
        error->setWordWrap(true);
        error->setMaximumWidth(360);
        layout->addWidget(error, 0, Qt::AlignVCenter);
        layout->addWidget(ui::linkButton(L10n::Common::Retry, [this] { m_session.loadMore(); }));
        return panel;
    }
    if (m_session.result().has_value() && m_session.result()->hasMore) {
        auto* more = ui::ghostButton(QStringLiteral("加载更多"));
        connect(more, &QPushButton::clicked, this, [this] {
            m_pendingScrollToEnd = true;
            m_session.loadMore();
        });
        layout->addWidget(more);
    }
    return panel;
}

void SearchView::renderAssist()
{
    if (!m_assistOpen) {
        m_assistHost->setVisible(false);
        clearLayout(m_assistLayout);
        return;
    }

    clearLayout(m_assistLayout);

    auto* panel = new QFrame(m_assistHost);
    panel->setObjectName(QStringLiteral("ctAssistPanel"));
    panel->setStyleSheet(QStringLiteral("QFrame#ctAssistPanel { background: %1; border: 1px solid %2; "
                                        "border-radius: %3px; }")
                             .arg(CTColors::panel().name(), CTColors::overlay().name())
                             .arg(CTRadius::Medium));
    auto* panelLayout = new QVBoxLayout(panel);
    panelLayout->setContentsMargins(0, 0, 0, 0);
    panelLayout->setSpacing(0);

    auto* closeRow = new QWidget(panel);
    auto* closeLayout = new QHBoxLayout(closeRow);
    closeLayout->setContentsMargins(0, 0, 0, 0);
    closeLayout->addStretch(1);
    closeLayout->addWidget(ui::linkButton(QStringLiteral("✕"), [this] { closeAssist(); }));
    panelLayout->addWidget(closeRow);

    const QString keyword = m_session.draftQuery().trimmed();
    if (!keyword.isEmpty()) {
        panelLayout->addWidget(buildSuggestions());
    } else {
        panelLayout->addWidget(buildHistory());
        panelLayout->addWidget(divider());
        panelLayout->addWidget(buildHotTerms());
    }

    m_assistLayout->addWidget(panel);
    m_assistHost->setVisible(true);
}

QWidget* SearchView::buildSuggestions()
{
    if (m_assist.isLoadingSuggestions() && m_assist.suggestions().isEmpty()) {
        return sectionMessage(QStringLiteral("搜索中…"));
    }
    if (m_assist.suggestions().isEmpty()) {
        return sectionMessage(QStringLiteral("没有联想结果"));
    }

    auto* rows = new QWidget();
    auto* layout = new QVBoxLayout(rows);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    for (const SearchSuggestion& suggestion : m_assist.suggestions()) {
        layout->addWidget(buildSuggestionRow(suggestion));
    }

    auto* area = new QScrollArea();
    area->setFrameShape(QFrame::NoFrame);
    area->setWidgetResizable(true);
    area->setMaximumHeight(320);
    area->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    area->setWidget(rows);
    area->setStyleSheet(QStringLiteral("QScrollArea { background: transparent; }"));
    return area;
}

QWidget* SearchView::buildSuggestionRow(const SearchSuggestion& suggestion)
{
    auto* row = new ui::CardButton();
    auto* layout = new QHBoxLayout(row);
    layout->setContentsMargins(CTSpacing::Lg, CTSpacing::Sm, CTSpacing::Lg, CTSpacing::Sm);
    layout->setSpacing(CTSpacing::Sm);

    auto* glyph = ui::secondaryLabel(kindGlyph(suggestion.suggestionKind));
    glyph->setFixedWidth(20);
    layout->addWidget(glyph);

    auto* text = new QWidget(row);
    auto* textLayout = new QVBoxLayout(text);
    textLayout->setContentsMargins(0, 0, 0, 0);
    textLayout->setSpacing(1);
    textLayout->addWidget(ui::titleElidedLabel(suggestion.title, CTTypography::Body, true));
    if (suggestion.subtitle.has_value() && !suggestion.subtitle->isEmpty()) {
        textLayout->addWidget(ui::secondaryElidedLabel(*suggestion.subtitle));
    }
    layout->addWidget(text, 1);

    layout->addWidget(ui::secondaryLabel(kindLabel(suggestion.suggestionKind)), 0, Qt::AlignVCenter);

    const SearchSuggestion copy = suggestion;
    row->onClicked = [this, copy] { pickSuggestion(copy); };
    return row;
}

QWidget* SearchView::buildHistory()
{
    auto* stack = new QWidget();
    auto* layout = new QVBoxLayout(stack);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    auto* header = new QWidget(stack);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(CTSpacing::Lg, CTSpacing::Md, CTSpacing::Lg, CTSpacing::Xs);
    auto* title = ui::secondaryLabel(QStringLiteral("搜索历史"));
    headerLayout->addWidget(title, 0, Qt::AlignVCenter);
    headerLayout->addStretch(1);
    if (!m_assist.history().isEmpty()) {
        headerLayout->addWidget(ui::linkButton(QStringLiteral("清空"), [this] {
            m_assist.clearHistory();
            renderAssist();
        }));
    }
    layout->addWidget(header);

    if (m_assist.history().isEmpty()) {
        layout->addWidget(sectionMessage(QStringLiteral("暂无搜索历史")));
        return stack;
    }

    auto* rows = new QWidget(stack);
    auto* rowsLayout = new QVBoxLayout(rows);
    rowsLayout->setContentsMargins(0, 0, 0, 0);
    rowsLayout->setSpacing(0);
    for (const QString& term : m_assist.history()) {
        auto* row = new QWidget(rows);
        auto* rowLayout = new QHBoxLayout(row);
        rowLayout->setContentsMargins(0, 0, 0, 0);
        rowLayout->setSpacing(0);

        const QString captured = term;
        auto* pick = ui::linkButton(captured, [this, captured] { pickTerm(captured); });
        pick->setStyleSheet(QStringLiteral(
            "QPushButton { color: %1; border: none; background: transparent; "
            "font-size: 14px; padding: 6px 16px; text-align: left; }")
                                .arg(CTColors::textPrimary().name()));
        rowLayout->addWidget(pick, 1);

        rowLayout->addWidget(ui::linkButton(QStringLiteral("✕"), [this, captured] {
            m_assist.removeHistory(captured);
            renderAssist();
        }));
        rowsLayout->addWidget(row);
    }

    auto* area = new QScrollArea();
    area->setFrameShape(QFrame::NoFrame);
    area->setWidgetResizable(true);
    area->setMaximumHeight(160);
    area->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    area->setWidget(rows);
    area->setStyleSheet(QStringLiteral("QScrollArea { background: transparent; }"));
    layout->addWidget(area);
    return stack;
}

QWidget* SearchView::buildHotTerms()
{
    auto* stack = new QWidget();
    auto* layout = new QVBoxLayout(stack);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    auto* header = new QWidget(stack);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(CTSpacing::Lg, 0, CTSpacing::Lg, CTSpacing::Xs);
    headerLayout->addWidget(ui::secondaryLabel(QStringLiteral("热门搜索")), 0, Qt::AlignVCenter);
    headerLayout->addStretch(1);
    if (m_assist.isLoadingHot()) {
        auto* progress = new QProgressBar(header);
        progress->setRange(0, 0);
        progress->setTextVisible(false);
        progress->setFixedWidth(60);
        progress->setFixedHeight(4);
        headerLayout->addWidget(progress, 0, Qt::AlignVCenter);
    }
    layout->addWidget(header);

    if (m_assist.hotError().has_value()) {
        auto* row = new QWidget(stack);
        auto* rowLayout = new QHBoxLayout(row);
        rowLayout->setContentsMargins(CTSpacing::Lg, 0, CTSpacing::Lg, CTSpacing::Md);
        auto* error = ui::secondaryLabel(*m_assist.hotError());
        error->setWordWrap(true);
        rowLayout->addWidget(error, 1);
        rowLayout->addWidget(ui::linkButton(
            L10n::Common::Retry, [this] { detach(m_assist.loadHotTermsAsync()); }));
        layout->addWidget(row);
        return stack;
    }

    if (m_assist.hotTerms().isEmpty() && !m_assist.isLoadingHot()) {
        layout->addWidget(sectionMessage(QStringLiteral("暂无热搜数据")));
        return stack;
    }

    auto* wrap = new QWidget(stack);
    auto* wrapLayout = new FlowLayout(wrap, CTSpacing::Sm);
    wrapLayout->setContentsMargins(CTSpacing::Lg, 0, CTSpacing::Lg, CTSpacing::Md);
    for (const HotSearchTerm& term : m_assist.hotTerms()) {
        const QString text = (!term.displayPrefix.has_value() || term.displayPrefix->isEmpty())
            ? term.keyword
            : QStringLiteral("%1 %2").arg(*term.displayPrefix, term.keyword);
        auto* button = ui::linkButton(text, [this, keyword = term.keyword] { pickTerm(keyword); });
        button->setStyleSheet(QStringLiteral(
            "QPushButton { color: %1; border: none; background: transparent; "
            "font-size: 12px; padding: 2px 6px; text-align: left; }")
                                  .arg(CTColors::textSecondary().name()));
        button->setToolTip(text);
        button->setAccessibleName(text);
        button->setText(button->fontMetrics().elidedText(text, Qt::ElideRight, 220));
        wrapLayout->addWidget(button);
    }
    layout->addWidget(wrap);
    return stack;
}

void SearchView::hookScrollbar(QScrollBar* bar)
{
    if (m_scrollConnection) {
        QObject::disconnect(m_scrollConnection);
        m_scrollConnection = QMetaObject::Connection();
    }
    m_scrollBar = bar;
    if (bar == nullptr) return;
    m_scrollConnection = connect(bar, &QScrollBar::valueChanged, this, [this] { onResultScroll(); });
}

void SearchView::onResultScroll()
{
    if (m_scrollBar == nullptr) return;
    if (m_scrollBar->maximum() <= 0) return;
    if (m_scrollBar->value() + m_scrollBar->pageStep() < m_scrollBar->maximum() - 64) return;
    if (m_session.isLoading() || m_session.isLoadingMore()) return;
    if (!m_session.result().has_value() || !m_session.result()->hasMore) return;
    m_pendingScrollToEnd = true;
    m_session.loadMore();
}

CT_REGISTER_PAGE(Page::Search, SearchView);

} // namespace ct
