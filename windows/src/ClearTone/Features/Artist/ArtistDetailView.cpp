#include "Features/Artist/ArtistDetailView.h"

#include "App/AppState.h"
#include "Core/Models/MusicSocialProvider.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "DesignSystem/L10n.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Playback/PlayerController.h"
#include "Providers/Netease/NeteaseProvider.h"
#include "Providers/Netease/NeteaseSocialProvider.h"

#include <QDialog>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QListWidget>
#include <QProgressBar>
#include <QPushButton>
#include <QScrollArea>
#include <QScrollBar>
#include <QVBoxLayout>

#include <utility>

namespace ct {

namespace {

IArtistProfileProvider* artistProvider()
{
    if (auto* provider = dynamic_cast<IArtistProfileProvider*>(AppState::shared().provider())) {
        return provider;
    }
    return &NeteaseProvider::shared();
}

IMusicSocialProvider& socialProvider()
{
    auto* session = AppState::shared().social();
    if (auto* social = dynamic_cast<IMusicSocialProvider*>(session)) return *social;
    return NeteaseSocialProvider::shared();
}

QString unknownUserMessage(const std::exception& error)
{
    return MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
}

void clearLayout(QLayout* layout, bool deleteWidgets = true)
{
    while (QLayoutItem* item = layout->takeAt(0)) {
        if (QWidget* widget = item->widget()) {
            if (deleteWidgets) widget->deleteLater();
        }
        if (QLayout* child = item->layout()) {
            clearLayout(child, deleteWidgets);
            if (deleteWidgets) child->deleteLater();
        }
        delete item;
    }
}

QWidget* statText(const QString& label, int value)
{
    auto* panel = new QWidget();
    auto* layout = new QHBoxLayout(panel);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(3);
    layout->addWidget(ui::titleLabel(QString::number(value), CTTypography::Body, true));
    layout->addWidget(ui::secondaryLabel(label));
    return panel;
}

void updateSongList(SongListView* view, const QList<Song>& songs)
{
    QStringList before;
    for (const Song& song : view->songs()) before.append(song.id);
    QStringList after;
    for (const Song& song : songs) after.append(song.id);
    if (before == after) return;
    QScrollBar* bar = view->listWidget()->verticalScrollBar();
    const int value = bar->value();
    view->setSongs(songs);
    bar->setValue(qMin(value, bar->maximum()));
}

QString trackCountText(int loaded, int total)
{
    if (total > loaded) return QStringLiteral("已加载 %1 / %2 首").arg(loaded).arg(total);
    return QStringLiteral("共 %1 首").arg(loaded);
}

} // namespace

ArtistDetailView::ArtistDetailView(QWidget* parent)
    : QWidget(parent)
    , m_session(QString(), artistProvider())
{
    setObjectName(QStringLiteral("ctArtistDetailView"));
    setStyleSheet(QStringLiteral("QWidget#ctArtistDetailView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    m_headerHost = new QWidget(this);
    m_headerLayout = new QVBoxLayout(m_headerHost);
    m_headerLayout->setContentsMargins(0, 0, 0, 0);
    m_headerLayout->setSpacing(0);
    root->addWidget(m_headerHost);

    m_tabsHost = new QWidget(this);
    m_tabsLayout = new QHBoxLayout(m_tabsHost);
    m_tabsLayout->setContentsMargins(CTSpacing::Xl, 0, CTSpacing::Xl, CTSpacing::Md);
    m_tabsLayout->setSpacing(CTSpacing::Sm);
    root->addWidget(m_tabsHost);

    m_contentHost = new QWidget(this);
    m_contentLayout = new QVBoxLayout(m_contentHost);
    m_contentLayout->setContentsMargins(0, 0, 0, 0);
    m_contentLayout->setSpacing(0);
    root->addWidget(m_contentHost, 1);

    m_statusHost = new QWidget(this);
    m_statusLayout = new QVBoxLayout(m_statusHost);
    m_statusLayout->setContentsMargins(0, 0, 0, 0);
    m_statusLayout->setSpacing(0);
    m_statusHost->setVisible(false);
    root->addWidget(m_statusHost, 1);

    m_hotList = new SongListView(this);

    m_songsPanel = new QWidget(this);
    auto* songsLayout = new QVBoxLayout(m_songsPanel);
    songsLayout->setContentsMargins(0, 0, 0, 0);
    songsLayout->setSpacing(0);
    m_songsHeader = ui::secondaryLabel(QString());
    m_songsHeader->setContentsMargins(CTSpacing::Xl, CTSpacing::Sm, CTSpacing::Xl, CTSpacing::Sm);
    songsLayout->addWidget(m_songsHeader);
    m_songsList = new SongListView(m_songsPanel);
    songsLayout->addWidget(m_songsList, 1);
    m_songsFooter = new QWidget(m_songsPanel);
    m_songsFooterLayout = new QVBoxLayout(m_songsFooter);
    m_songsFooterLayout->setContentsMargins(0, 0, 0, 0);
    m_songsFooterLayout->setSpacing(0);
    songsLayout->addWidget(m_songsFooter);

    m_albumsPanel = new QWidget(this);
    auto* albumsLayout = new QVBoxLayout(m_albumsPanel);
    albumsLayout->setContentsMargins(0, 0, 0, 0);
    albumsLayout->setSpacing(0);
    m_albumsGridHost = new QWidget();
    m_albumsGrid = new QGridLayout(m_albumsGridHost);
    m_albumsGrid->setContentsMargins(CTSpacing::Xl, 0, CTSpacing::Xl, 0);
    m_albumsGrid->setHorizontalSpacing(CTSpacing::Lg);
    m_albumsGrid->setVerticalSpacing(CTSpacing::Lg);
    m_albumsScroll = ui::scrollWrapper(m_albumsGridHost);
    albumsLayout->addWidget(m_albumsScroll, 1);
    m_albumsFooter = new QWidget(m_albumsPanel);
    m_albumsFooterLayout = new QVBoxLayout(m_albumsFooter);
    m_albumsFooterLayout->setContentsMargins(0, 0, 0, 0);
    m_albumsFooterLayout->setSpacing(0);
    albumsLayout->addWidget(m_albumsFooter);

    m_mvsPanel = new QWidget(this);
    auto* mvsLayout = new QVBoxLayout(m_mvsPanel);
    mvsLayout->setContentsMargins(0, 0, 0, 0);
    mvsLayout->setSpacing(0);
    m_mvsGridHost = new QWidget();
    m_mvsGrid = new QGridLayout(m_mvsGridHost);
    m_mvsGrid->setContentsMargins(CTSpacing::Xl, 0, CTSpacing::Xl, 0);
    m_mvsGrid->setHorizontalSpacing(CTSpacing::Lg);
    m_mvsGrid->setVerticalSpacing(CTSpacing::Lg);
    m_mvsScroll = ui::scrollWrapper(m_mvsGridHost);
    mvsLayout->addWidget(m_mvsScroll, 1);
    m_mvsFooter = new QWidget(m_mvsPanel);
    m_mvsFooterLayout = new QVBoxLayout(m_mvsFooter);
    m_mvsFooterLayout->setContentsMargins(0, 0, 0, 0);
    m_mvsFooterLayout->setSpacing(0);
    mvsLayout->addWidget(m_mvsFooter);

    m_aboutBody = new QWidget();
    m_aboutLayout = new QVBoxLayout(m_aboutBody);
    m_aboutLayout->setContentsMargins(CTSpacing::Xl, 0, CTSpacing::Xl, CTSpacing::Xl);
    m_aboutLayout->setSpacing(CTSpacing::Xl);
    m_aboutScroll = ui::scrollWrapper(m_aboutBody);

    m_session.onChanged = [this, alive = m_alive] {
        if (!*alive) return;
        scheduleRender();
    };

    connect(m_songsList->listWidget()->verticalScrollBar(), &QScrollBar::valueChanged, this,
        [this](int value) {
            if (!m_session.canLoadMoreSongs()) return;
            QScrollBar* bar = m_songsList->listWidget()->verticalScrollBar();
            if (value >= bar->maximum() - 24) detach(loadMoreSongsAsync());
        });
    connect(m_albumsScroll->verticalScrollBar(), &QScrollBar::valueChanged, this, [this](int value) {
        if (!m_session.canLoadMoreAlbums()) return;
        QScrollBar* bar = m_albumsScroll->verticalScrollBar();
        if (value >= bar->maximum() - 24) detach(loadMoreAlbumsAsync());
    });
    connect(m_mvsScroll->verticalScrollBar(), &QScrollBar::valueChanged, this, [this](int value) {
        if (!m_session.canLoadMoreMVs()) return;
        QScrollBar* bar = m_mvsScroll->verticalScrollBar();
        if (value >= bar->maximum() - 24) detach(loadMoreMVsAsync());
    });

    m_lastDataContextKey = AppState::shared().dataContextKey();
    m_appObserver = AppState::shared().changed.subscribe([this] { scheduleAppChange(); });
    render();
}

ArtistDetailView::~ArtistDetailView()
{
    *m_alive = false;
    AppState::shared().changed.unsubscribe(m_appObserver);
}

void ArtistDetailView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    m_isAttached = true;
    load();
}

void ArtistDetailView::hideEvent(QHideEvent* event)
{
    QWidget::hideEvent(event);
    m_isAttached = false;
}

void ArtistDetailView::resizeEvent(QResizeEvent* event)
{
    QWidget::resizeEvent(event);
    if (!*m_alive || m_albumsPanel == nullptr) return;
    if (m_currentContent == m_albumsPanel && gridColumns(140) != m_lastAlbumColumns) {
        refreshAlbumsGrid();
    } else if (m_currentContent == m_mvsPanel && gridColumns(200) != m_lastMvColumns) {
        refreshMvsGrid();
    }
}

int ArtistDetailView::gridColumns(int cardWidth) const
{
    const int available = qMax(0, width() - 2 * static_cast<int>(CTSpacing::Xl));
    return qMax(1, available / (cardWidth + static_cast<int>(CTSpacing::Lg)));
}

void ArtistDetailView::scheduleAppChange()
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

void ArtistDetailView::scheduleRender()
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

void ArtistDetailView::handleAppChange()
{
    if (!*m_alive) return;
    const QString key = AppState::shared().dataContextKey();
    const bool contextChanged = key != m_lastDataContextKey;
    const std::optional<QString> selected = AppState::shared().selectedArtistID();

    if (selected != m_activeArtistID) {
        if (m_isAttached) load();
        return;
    }
    if (contextChanged && m_isAttached) load();
}

void ArtistDetailView::load()
{
    const std::optional<QString> id = AppState::shared().selectedArtistID();
    if (!id.has_value() || id->isEmpty()) {
        m_activeArtistID.reset();
        m_session.switchTo(QString());
        resetCollections();
        render();
        return;
    }

    const QString key = AppState::shared().dataContextKey();
    const bool dataContextChanged = key != m_lastDataContextKey;
    m_lastDataContextKey = key;
    if (m_activeArtistID != id) {
        m_activeArtistID = id;
        m_tab = ArtistTab::Hot;
        m_actionError.reset();
        m_session.switchTo(*id);
        resetCollections();
    } else if (dataContextChanged) {
        m_session.reloadForDataContext();
        resetCollections();
    }

    const quint64 token = ++m_loadToken;
    render();
    detach(loadAsync(token));
}

Task<void> ArtistDetailView::loadAsync(quint64 token)
{
    auto alive = m_alive;
    try {
        co_await m_session.loadProfileAsync(CancellationToken::none());
        if (!*alive || token != m_loadToken) co_return;
        render();
        co_await m_session.loadHighlightsAsync(CancellationToken::none());
        if (!*alive || token != m_loadToken) co_return;
        render();
    } catch (const MusicException& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_actionError = error.userFacingMessage();
        render();
    } catch (const std::exception& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_actionError = unknownUserMessage(error);
        render();
    }
}

Task<void> ArtistDetailView::loadTabAsync(ArtistTab tab)
{
    auto alive = m_alive;
    const quint64 token = m_loadToken;
    try {
        switch (tab) {
        case ArtistTab::Hot:
            if (m_session.hotSongs().isEmpty()) co_await m_session.loadHighlightsAsync();
            break;
        case ArtistTab::Songs:
            if (m_session.songs().isEmpty()) co_await m_session.loadSongsAsync();
            break;
        case ArtistTab::Albums:
            if (m_session.albums().isEmpty()) co_await m_session.loadAlbumsAsync();
            break;
        case ArtistTab::MVs:
            if (m_session.mvs().isEmpty()) co_await m_session.loadMVsAsync();
            break;
        case ArtistTab::About:
            if (!m_session.intro().has_value()) co_await m_session.loadIntroAsync();
            break;
        }
    } catch (const MusicException& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_actionError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_actionError = unknownUserMessage(error);
    }
    if (!*alive || token != m_loadToken || m_tab != tab) co_return;
    render();
}

Task<void> ArtistDetailView::loadMoreSongsAsync()
{
    auto alive = m_alive;
    if (!m_session.canLoadMoreSongs()) co_return;
    try {
        co_await m_session.loadMoreSongsAsync();
    } catch (const MusicException& error) {
        if (!*alive) co_return;
        m_actionError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive) co_return;
        m_actionError = unknownUserMessage(error);
    }
    if (!*alive) co_return;
    renderSongs();
    renderHeader();
}

Task<void> ArtistDetailView::loadMoreAlbumsAsync()
{
    auto alive = m_alive;
    if (!m_session.canLoadMoreAlbums()) co_return;
    try {
        co_await m_session.loadMoreAlbumsAsync();
    } catch (const MusicException& error) {
        if (!*alive) co_return;
        m_actionError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive) co_return;
        m_actionError = unknownUserMessage(error);
    }
    if (!*alive) co_return;
    renderAlbums();
}

Task<void> ArtistDetailView::loadMoreMVsAsync()
{
    auto alive = m_alive;
    if (!m_session.canLoadMoreMVs()) co_return;
    try {
        co_await m_session.loadMoreMVsAsync();
    } catch (const MusicException& error) {
        if (!*alive) co_return;
        m_actionError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive) co_return;
        m_actionError = unknownUserMessage(error);
    }
    if (!*alive) co_return;
    renderMVs();
}

Task<void> ArtistDetailView::toggleFollowAsync(bool follow, quint64 token)
{
    auto alive = m_alive;
    const std::optional<QString> id = m_activeArtistID;
    if (!id.has_value() || m_isSubscribing) co_return;
    m_isSubscribing = true;
    renderHeader();
    bool ok = true;
    try {
        co_await socialProvider().subscribeArtist(*id, follow, CancellationToken::none());
    } catch (const MusicException& error) {
        ok = false;
        if (*alive && token == m_loadToken) {
            AppState::shared().publishWriteError(error);
            m_actionError = error.userFacingMessage();
        }
    } catch (const std::exception& error) {
        ok = false;
        if (*alive && token == m_loadToken) {
            m_actionError = unknownUserMessage(error);
        }
    }
    if (!*alive) co_return;
    m_isSubscribing = false;
    if (ok && token == m_loadToken) {
        m_session.setFollowed(follow);
        m_actionError.reset();
    }
    if (token == m_loadToken) renderHeader();
    co_return;
}

void ArtistDetailView::resetCollections()
{
    m_hotList->setSongs({});
    m_songsList->setSongs({});
    clearLayout(m_albumsGrid);
    clearLayout(m_mvsGrid);

    QWidget* previous = m_currentContent;
    m_currentContent = nullptr;
    while (QLayoutItem* item = m_contentLayout->takeAt(0)) delete item;
    if (previous != nullptr) {
        previous->hide();
        const bool persistent = previous == m_hotList || previous == m_songsPanel
            || previous == m_albumsPanel || previous == m_mvsPanel || previous == m_aboutScroll;
        if (!persistent) previous->deleteLater();
    }
    const QList<QWidget*> panels
        = {m_hotList, m_songsPanel, m_albumsPanel, m_mvsPanel, m_aboutScroll};
    for (QWidget* panel : panels) panel->hide();
    m_lastAlbumColumns = 0;
    m_lastMvColumns = 0;
}

void ArtistDetailView::switchTab(ArtistTab tab)
{
    if (m_tab == tab) return;
    m_tab = tab;
    renderTabs();
    renderTabContent();
    detach(loadTabAsync(tab));
}

void ArtistDetailView::render()
{
    if (!*m_alive) return;
    if (!m_session.profile().has_value()) {
        if (m_session.isLoadingProfile()) {
            showStatus(ui::statusPanel(L10n::Common::Loading, true));
        } else if (m_session.profileError().has_value()) {
            showStatus(ui::errorPanel(*m_session.profileError(), [this] { load(); }));
        } else {
            showStatus(ui::statusPanel(QStringLiteral("暂无内容"), false));
        }
        return;
    }

    m_statusHost->setVisible(false);
    m_headerHost->setVisible(true);
    m_tabsHost->setVisible(true);
    m_contentHost->setVisible(true);
    renderHeader();
    renderTabs();
    renderTabContent();
}

void ArtistDetailView::showStatus(QWidget* status)
{
    clearLayout(m_statusLayout);
    if (status != nullptr) m_statusLayout->addWidget(status);
    m_statusHost->setVisible(true);
    m_headerHost->setVisible(false);
    m_tabsHost->setVisible(false);
    m_contentHost->setVisible(false);
}

void ArtistDetailView::renderHeader()
{
    clearLayout(m_headerLayout);
    if (m_session.profile().has_value()) m_headerLayout->addWidget(buildHeader());
}

QWidget* ArtistDetailView::buildHeader()
{
    const ArtistProfile profile = *m_session.profile();

    auto* header = new QWidget();
    auto* layout = new QHBoxLayout(header);
    layout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Md);
    layout->setSpacing(CTSpacing::Lg);

    auto* avatar = new CoverImage(header);
    avatar->setFixedSize(140, 140);
    avatar->setCornerRadius(70);
    avatar->setCoverURL(profile.artist.avatarURL, 280);
    layout->addWidget(avatar, 0, Qt::AlignTop);

    auto* info = new QWidget(header);
    auto* infoLayout = new QVBoxLayout(info);
    infoLayout->setContentsMargins(CTSpacing::Lg, 0, 0, 0);
    infoLayout->setSpacing(CTSpacing::Sm);

    auto* name = ui::titleLabel(profile.artist.displayNameWithAlias(), CTTypography::PageTitle, true);
    name->setWordWrap(true);
    infoLayout->addWidget(name);

    auto* stats = new QWidget(info);
    auto* statsLayout = new QHBoxLayout(stats);
    statsLayout->setContentsMargins(0, 0, 0, 0);
    statsLayout->setSpacing(CTSpacing::Lg);
    statsLayout->addWidget(statText(QStringLiteral("单曲"), profile.songCount));
    statsLayout->addWidget(statText(QStringLiteral("专辑"), profile.albumCount));
    statsLayout->addWidget(statText(QStringLiteral("MV"), profile.mvCount));
    statsLayout->addStretch(1);
    infoLayout->addWidget(stats);

    if (profile.briefDescription.has_value() && !profile.briefDescription->isEmpty()) {
        auto* brief = ui::secondaryLabel(*profile.briefDescription);
        brief->setWordWrap(true);
        brief->setMaximumWidth(520);
        infoLayout->addWidget(brief);
    }

    if (!profile.identifyTags.isEmpty()) {
        auto* tags = new QWidget(info);
        auto* tagsLayout = new QHBoxLayout(tags);
        tagsLayout->setContentsMargins(0, 0, 0, 0);
        tagsLayout->setSpacing(CTSpacing::Xs);
        for (const QString& tag : profile.identifyTags) {
            auto* chip = new QLabel(tag, tags);
            chip->setStyleSheet(QStringLiteral("background: %1; color: %2; border-radius: 10px;"
                                               " padding: 2px 8px; font-size: 12px;")
                                    .arg(CTColors::overlay().name(), CTColors::textSecondary().name()));
            tagsLayout->addWidget(chip);
        }
        tagsLayout->addStretch(1);
        infoLayout->addWidget(tags);
    }

    auto* actions = new QWidget(info);
    auto* actionsLayout = new QHBoxLayout(actions);
    actionsLayout->setContentsMargins(0, 0, 0, 0);
    actionsLayout->setSpacing(CTSpacing::Md);

    const QList<Song> hotSongs = m_session.hotSongs();
    auto* playHot = ui::accentButton(QStringLiteral("播放热门"));
    playHot->setEnabled(!hotSongs.isEmpty());
    connect(playHot, &QPushButton::clicked, this, [hotSongs] {
        PlayerController::shared().playSongs(hotSongs, 0);
    });
    actionsLayout->addWidget(playHot);

    const QList<Song> songs = m_session.songs();
    auto* playAll = ui::ghostButton(QStringLiteral("播放全部"));
    playAll->setEnabled(!songs.isEmpty() && !m_session.canLoadMoreSongs());
    connect(playAll, &QPushButton::clicked, this, [songs] {
        PlayerController::shared().playSongs(songs, 0);
    });
    actionsLayout->addWidget(playAll);

    if (AppState::shared().canPerformWrite()) {
        const bool followed = m_session.isFollowed().value_or(false);
        auto* subscribe = ui::ghostButton(followed ? QStringLiteral("取消关注")
                                                   : QStringLiteral("关注歌手"));
        subscribe->setEnabled(!m_isSubscribing);
        connect(subscribe, &QPushButton::clicked, this, [this, followed] {
            detach(toggleFollowAsync(!followed, m_loadToken));
        });
        actionsLayout->addWidget(subscribe);
    }

    actionsLayout->addWidget(ui::linkButton(QStringLiteral("歌手简介"), [this] { showIntroDialog(); }));
    actionsLayout->addStretch(1);
    infoLayout->addWidget(actions);

    if (m_actionError.has_value()) {
        auto* error = ui::secondaryLabel(*m_actionError);
        error->setWordWrap(true);
        infoLayout->addWidget(error);
    }
    infoLayout->addStretch(1);

    layout->addWidget(info, 1);
    return header;
}

QString ArtistDetailView::tabName(ArtistTab tab) const
{
    switch (tab) {
    case ArtistTab::Hot:
        return QStringLiteral("热门");
    case ArtistTab::Songs:
        return QStringLiteral("全部歌曲");
    case ArtistTab::Albums:
        return QStringLiteral("专辑");
    case ArtistTab::MVs:
        return QStringLiteral("MV");
    case ArtistTab::About:
        return QStringLiteral("歌手详情");
    }
    return QStringLiteral("歌手详情");
}

void ArtistDetailView::renderTabs()
{
    clearLayout(m_tabsLayout);
    for (const ArtistTab tab :
        {ArtistTab::Hot, ArtistTab::Songs, ArtistTab::Albums, ArtistTab::MVs, ArtistTab::About}) {
        QPushButton* button = nullptr;
        if (tab == m_tab) button = ui::accentButton(tabName(tab));
        else button = ui::ghostButton(tabName(tab));
        connect(button, &QPushButton::clicked, this, [this, tab] { switchTab(tab); });
        m_tabsLayout->addWidget(button);
    }
    m_tabsLayout->addStretch(1);
}

void ArtistDetailView::renderTabContent()
{
    switch (m_tab) {
    case ArtistTab::Hot:
        renderHot();
        break;
    case ArtistTab::Songs:
        renderSongs();
        break;
    case ArtistTab::Albums:
        renderAlbums();
        break;
    case ArtistTab::MVs:
        renderMVs();
        break;
    case ArtistTab::About:
        renderAbout();
        break;
    }
}

void ArtistDetailView::showContent(QWidget* content)
{
    if (m_currentContent == content) return;
    QWidget* previous = m_currentContent;
    m_currentContent = nullptr;
    if (previous != nullptr) {
        previous->hide();
        const bool persistent = previous == m_hotList || previous == m_songsPanel
            || previous == m_albumsPanel || previous == m_mvsPanel || previous == m_aboutScroll;
        if (!persistent) previous->deleteLater();
    }
    while (QLayoutItem* item = m_contentLayout->takeAt(0)) delete item;
    m_currentContent = content;
    m_contentLayout->addWidget(content, 1);
    content->show();
}

void ArtistDetailView::renderHot()
{
    if (m_session.hotSongs().isEmpty() && m_session.isLoadingHighlights()) {
        showContent(ui::statusPanel(L10n::Common::Loading, true));
        return;
    }
    if (m_session.hotSongs().isEmpty()) {
        showContent(ui::statusPanel(QStringLiteral("暂无内容"), false));
        return;
    }
    updateSongList(m_hotList, m_session.hotSongs());
    showContent(m_hotList);
}

void ArtistDetailView::renderSongs()
{
    if (m_session.songs().isEmpty()) {
        if (m_session.songsError().has_value()) {
            showContent(ui::errorPanel(*m_session.songsError(),
                [this] { detach(loadTabAsync(ArtistTab::Songs)); }));
        } else if (m_session.isLoadingSongs()) {
            showContent(ui::statusPanel(L10n::Common::Loading, true));
        } else {
            showContent(ui::statusPanel(QStringLiteral("暂无内容"), false));
        }
        return;
    }

    updateSongList(m_songsList, m_session.songs());
    m_songsHeader->setText(trackCountText(m_session.songs().size(), m_session.songsTotal()));
    clearLayout(m_songsFooterLayout);
    m_songsFooterLayout->addWidget(buildPaginationFooter(m_session.isLoadingMoreSongs(),
        m_session.canLoadMoreSongs(), m_session.songsError(),
        [this] { detach(loadMoreSongsAsync()); }));
    showContent(m_songsPanel);
}

void ArtistDetailView::renderAlbums()
{
    if (m_session.albums().isEmpty()) {
        if (m_session.albumsError().has_value()) {
            showContent(ui::errorPanel(*m_session.albumsError(),
                [this] { detach(loadTabAsync(ArtistTab::Albums)); }));
        } else if (m_session.isLoadingAlbums()) {
            showContent(ui::statusPanel(L10n::Common::Loading, true));
        } else {
            showContent(ui::statusPanel(QStringLiteral("暂无内容"), false));
        }
        return;
    }

    refreshAlbumsGrid();
    clearLayout(m_albumsFooterLayout);
    m_albumsFooterLayout->addWidget(buildPaginationFooter(m_session.isLoadingMoreAlbums(),
        m_session.canLoadMoreAlbums(), m_session.albumsError(),
        [this] { detach(loadMoreAlbumsAsync()); }));
    showContent(m_albumsPanel);
}

void ArtistDetailView::renderMVs()
{
    if (m_session.mvs().isEmpty()) {
        if (m_session.mvsError().has_value()) {
            showContent(ui::errorPanel(*m_session.mvsError(),
                [this] { detach(loadTabAsync(ArtistTab::MVs)); }));
        } else if (m_session.isLoadingMVs()) {
            showContent(ui::statusPanel(L10n::Common::Loading, true));
        } else {
            showContent(ui::statusPanel(QStringLiteral("暂无内容"), false));
        }
        return;
    }

    refreshMvsGrid();
    clearLayout(m_mvsFooterLayout);
    m_mvsFooterLayout->addWidget(buildPaginationFooter(m_session.isLoadingMoreMVs(),
        m_session.canLoadMoreMVs(), m_session.mvsError(),
        [this] { detach(loadMoreMVsAsync()); }));
    showContent(m_mvsPanel);
}

void ArtistDetailView::renderAbout()
{
    clearLayout(m_aboutLayout);
    if (m_session.intro().has_value()) {
        const ArtistIntro intro = *m_session.intro();
        if (intro.briefDescription.has_value() && !intro.briefDescription->isEmpty()) {
            auto* brief = ui::secondaryLabel(*intro.briefDescription);
            brief->setWordWrap(true);
            m_aboutLayout->addWidget(buildAboutSection(QStringLiteral("简介"), brief));
        }
        for (const ArtistIntroSection& section : intro.sections) {
            auto* body = ui::secondaryLabel(section.body);
            body->setWordWrap(true);
            m_aboutLayout->addWidget(buildAboutSection(section.title, body));
        }
    } else if (m_session.isLoadingIntro()) {
        m_aboutLayout->addWidget(ui::statusPanel(L10n::Common::Loading, true));
    } else if (m_session.introError().has_value()) {
        m_aboutLayout->addWidget(ui::errorPanel(*m_session.introError(),
            [this] { detach(loadTabAsync(ArtistTab::About)); }));
    } else {
        m_aboutLayout->addWidget(ui::statusPanel(QStringLiteral("暂无内容"), false));
    }

    if (!m_session.similarArtists().isEmpty()) {
        auto* gridHost = new QWidget();
        auto* grid = new QGridLayout(gridHost);
        grid->setContentsMargins(0, 0, 0, 0);
        grid->setHorizontalSpacing(CTSpacing::Lg);
        grid->setVerticalSpacing(CTSpacing::Lg);
        const QList<Artist> similar = m_session.similarArtists();
        const int columns = 6;
        for (int index = 0; index < similar.size(); ++index) {
            auto* card = ui::artistCard(similar.at(index),
                [](const Artist& artist) { AppState::shared().openArtist(artist.id); });
            grid->addWidget(card, index / columns, index % columns,
                Qt::AlignTop | Qt::AlignLeft);
        }
        grid->setColumnStretch(columns, 1);
        m_aboutLayout->addWidget(buildAboutSection(QStringLiteral("相似歌手"), gridHost));
    }
    m_aboutLayout->addStretch(1);

    showContent(m_aboutScroll);
}

QWidget* ArtistDetailView::buildAboutSection(const QString& title, QWidget* content)
{
    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Sm);
    if (!title.isEmpty()) {
        layout->addWidget(ui::titleLabel(title, CTTypography::SectionTitle, true));
    }
    layout->addWidget(content);
    return panel;
}

QWidget* ArtistDetailView::buildPaginationFooter(bool isLoading, bool canLoadMore,
    const std::optional<QString>& error, std::function<void()> retry)
{
    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, CTSpacing::Md, 0, CTSpacing::Md);
    layout->setSpacing(CTSpacing::Sm);
    layout->setAlignment(Qt::AlignHCenter);

    if (isLoading) {
        auto* progress = new QProgressBar(panel);
        progress->setRange(0, 0);
        progress->setTextVisible(false);
        progress->setFixedWidth(160);
        progress->setFixedHeight(4);
        layout->addWidget(progress, 0, Qt::AlignHCenter);
    } else if (error.has_value() && canLoadMore) {
        auto* label = ui::secondaryLabel(*error);
        label->setWordWrap(true);
        label->setAlignment(Qt::AlignCenter);
        layout->addWidget(label, 0, Qt::AlignHCenter);
        layout->addWidget(ui::linkButton(L10n::Common::Retry, retry), 0, Qt::AlignHCenter);
    } else if (canLoadMore) {
        auto* more = ui::ghostButton(QStringLiteral("加载更多"));
        connect(more, &QPushButton::clicked, this, [retry] {
            if (retry) retry();
        });
        layout->addWidget(more, 0, Qt::AlignHCenter);
    } else if (error.has_value()) {
        auto* label = ui::secondaryLabel(*error);
        label->setAlignment(Qt::AlignCenter);
        layout->addWidget(label, 0, Qt::AlignHCenter);
    }
    return panel;
}

void ArtistDetailView::refreshAlbumsGrid()
{
    const int scrollValue = m_albumsScroll->verticalScrollBar()->value();
    clearLayout(m_albumsGrid);
    const QList<Album> albums = m_session.albums();
    const int columns = gridColumns(140);
    m_lastAlbumColumns = columns;
    for (int index = 0; index < albums.size(); ++index) {
        auto* card = ui::albumCard(albums.at(index),
            [](const Album& album) { AppState::shared().openAlbum(album.id); }, 140);
        m_albumsGrid->addWidget(card, index / columns, index % columns,
            Qt::AlignTop | Qt::AlignLeft);
    }
    m_albumsGrid->setColumnStretch(columns, 1);
    m_albumsScroll->verticalScrollBar()->setValue(
        qMin(scrollValue, m_albumsScroll->verticalScrollBar()->maximum()));
}

QWidget* ArtistDetailView::buildMvCard(const ArtistMV& mv)
{
    auto* card = new QWidget();
    card->setFixedWidth(200);
    auto* layout = new QVBoxLayout(card);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(6);

    auto* cover = new CoverImage(card);
    cover->setFixedSize(200, 112);
    cover->setCornerRadius(CTRadius::Small);
    cover->setCoverURL(mv.coverURL, 400);
    layout->addWidget(cover);

    auto* name = ui::titleLabel(mv.name, CTTypography::Body, true);
    name->setMaximumWidth(200);
    layout->addWidget(name);

    QStringList parts;
    if (mv.artistName.has_value() && !mv.artistName->isEmpty()) parts.append(*mv.artistName);
    if (mv.playCount > 0) parts.append(QStringLiteral("播放 %1").arg(CTFormatting::count(mv.playCount)));
    if (mv.duration > 0) parts.append(CTFormatting::time(mv.duration));
    auto* sub = ui::secondaryLabel(parts.join(QStringLiteral(" · ")));
    sub->setMaximumWidth(200);
    layout->addWidget(sub);
    return card;
}

void ArtistDetailView::refreshMvsGrid()
{
    const int scrollValue = m_mvsScroll->verticalScrollBar()->value();
    clearLayout(m_mvsGrid);
    const QList<ArtistMV> mvs = m_session.mvs();
    const int columns = gridColumns(200);
    m_lastMvColumns = columns;
    for (int index = 0; index < mvs.size(); ++index) {
        m_mvsGrid->addWidget(buildMvCard(mvs.at(index)), index / columns, index % columns,
            Qt::AlignTop | Qt::AlignLeft);
    }
    m_mvsGrid->setColumnStretch(columns, 1);
    m_mvsScroll->verticalScrollBar()->setValue(
        qMin(scrollValue, m_mvsScroll->verticalScrollBar()->maximum()));
}

Task<void> ArtistDetailView::loadIntroForDialogAsync()
{
    auto alive = m_alive;
    try {
        co_await m_session.loadIntroAsync();
    } catch (const MusicException&) {
    } catch (const std::exception&) {
    }
    if (!*alive) co_return;
    populateIntroDialog();
}

void ArtistDetailView::showIntroDialog()
{
    if (m_introDialog != nullptr) {
        m_introDialog->raise();
        m_introDialog->activateWindow();
        return;
    }

    auto* dialog = new QDialog(this);
    dialog->setAttribute(Qt::WA_DeleteOnClose);
    dialog->setWindowTitle(QStringLiteral("歌手简介"));
    dialog->setModal(true);
    dialog->resize(560, 520);
    dialog->setStyleSheet(QStringLiteral("QDialog { background: %1; }").arg(CTColors::panel().name()));

    auto* layout = new QVBoxLayout(dialog);
    layout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl);
    layout->setSpacing(CTSpacing::Md);

    const QString name = m_session.profile().has_value()
        ? m_session.profile()->artist.displayNameWithAlias()
        : QStringLiteral("歌手简介");
    layout->addWidget(ui::titleLabel(name, CTTypography::SectionTitle, true));

    auto* body = new QWidget();
    auto* bodyLayout = new QVBoxLayout(body);
    bodyLayout->setContentsMargins(0, 0, 0, 0);
    bodyLayout->setSpacing(CTSpacing::Md);
    auto* scroll = ui::scrollWrapper(body);
    layout->addWidget(scroll, 1);

    m_introDialog = dialog;
    m_introDialogLayout = bodyLayout;
    populateIntroDialog();

    if (!m_session.intro().has_value() && !m_session.isLoadingIntro()) {
        detach(loadIntroForDialogAsync());
    }
    dialog->open();
}

void ArtistDetailView::populateIntroDialog()
{
    if (m_introDialog == nullptr || m_introDialogLayout == nullptr) return;
    clearLayout(m_introDialogLayout);

    if (m_session.intro().has_value()) {
        const ArtistIntro intro = *m_session.intro();
        if (intro.briefDescription.has_value() && !intro.briefDescription->isEmpty()) {
            auto* brief = ui::secondaryLabel(*intro.briefDescription);
            brief->setWordWrap(true);
            m_introDialogLayout->addWidget(brief);
        }
        for (const ArtistIntroSection& section : intro.sections) {
            if (!section.title.isEmpty()) {
                m_introDialogLayout->addWidget(
                    ui::titleLabel(section.title, CTTypography::Body, true));
            }
            auto* body = ui::secondaryLabel(section.body);
            body->setWordWrap(true);
            m_introDialogLayout->addWidget(body);
        }
        m_introDialogLayout->addStretch(1);
    } else if (m_session.isLoadingIntro()) {
        m_introDialogLayout->addWidget(ui::statusPanel(L10n::Common::Loading, true));
    } else if (m_session.introError().has_value()) {
        m_introDialogLayout->addWidget(ui::errorPanel(*m_session.introError(),
            [this] { detach(loadIntroForDialogAsync()); }));
    } else {
        m_introDialogLayout->addWidget(ui::statusPanel(QStringLiteral("暂无内容"), false));
    }
}

CT_REGISTER_PAGE(Page::ArtistDetail, ArtistDetailView);

} // namespace ct
