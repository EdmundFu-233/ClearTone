#include "Features/Album/AlbumDetailView.h"

#include "App/AppState.h"
#include "Core/Models/MusicSocialProvider.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "DesignSystem/L10n.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Playback/PlayerController.h"
#include "Providers/Netease/NeteaseSocialProvider.h"

#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QScrollArea>
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

} // namespace

AlbumDetailView::AlbumDetailView(QWidget* parent)
    : QWidget(parent)
{
    setObjectName(QStringLiteral("ctAlbumDetailView"));
    setStyleSheet(QStringLiteral("QWidget#ctAlbumDetailView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    m_headerHost = new QWidget(this);
    m_headerLayout = new QVBoxLayout(m_headerHost);
    m_headerLayout->setContentsMargins(0, 0, 0, 0);
    m_headerLayout->setSpacing(0);
    root->addWidget(m_headerHost);

    m_bodyPanel = new QWidget();
    m_bodyLayout = new QVBoxLayout(m_bodyPanel);
    m_bodyLayout->setContentsMargins(0, 0, 0, CTSpacing::Xl);
    m_bodyLayout->setSpacing(CTSpacing::Sm);

    m_trackList = new SongListView(m_bodyPanel);
    m_bodyLayout->addWidget(m_trackList);

    m_similarHeader = ui::titleLabel(QStringLiteral("相似歌曲"), CTTypography::SectionTitle, true);
    m_similarHeader->setVisible(false);
    m_bodyLayout->addWidget(m_similarHeader);

    m_similarList = new SongListView(m_bodyPanel);
    m_similarList->setVisible(false);
    m_bodyLayout->addWidget(m_similarList);
    m_bodyLayout->addStretch(1);

    m_bodyScroll = ui::scrollWrapper(m_bodyPanel);
    root->addWidget(m_bodyScroll, 1);

    m_statusHost = new QWidget(this);
    m_statusLayout = new QVBoxLayout(m_statusHost);
    m_statusLayout->setContentsMargins(0, 0, 0, 0);
    m_statusLayout->setSpacing(0);
    m_statusHost->setVisible(false);
    root->addWidget(m_statusHost, 1);

    m_lastDataContextKey = AppState::shared().dataContextKey();
    m_appObserver = AppState::shared().changed.subscribe([this] { scheduleAppChange(); });
    render();
}

AlbumDetailView::~AlbumDetailView()
{
    *m_alive = false;
    AppState::shared().changed.unsubscribe(m_appObserver);
}

void AlbumDetailView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    m_isAttached = true;
    load();
}

void AlbumDetailView::hideEvent(QHideEvent* event)
{
    QWidget::hideEvent(event);
    m_isAttached = false;
}

void AlbumDetailView::scheduleAppChange()
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

void AlbumDetailView::handleAppChange()
{
    if (!*m_alive) return;
    const QString key = AppState::shared().dataContextKey();
    const bool contextChanged = key != m_lastDataContextKey;
    if (contextChanged) m_lastDataContextKey = key;

    const std::optional<QString> selected = AppState::shared().selectedAlbumID();
    if (selected != m_albumID) {
        if (m_isAttached) load();
        return;
    }
    if (contextChanged && m_isAttached) load();
}

void AlbumDetailView::load()
{
    const std::optional<QString> id = AppState::shared().selectedAlbumID();
    if (!id.has_value() || id->isEmpty()) {
        m_albumID.reset();
        m_detail.reset();
        m_isLoading = false;
        m_errorMessage.reset();
        m_isSubscribed.reset();
        m_actionError.reset();
        m_trackList->setSongs({});
        m_similarList->setSongs({});
        m_similarHeader->setVisible(false);
        m_similarList->setVisible(false);
        refreshTrackHeights();
        render();
        return;
    }

    const quint64 token = ++m_loadToken;
    m_albumID = id;
    m_isLoading = true;
    m_errorMessage.reset();
    m_actionError.reset();
    m_detail.reset();
    m_isSubscribed.reset();
    m_trackList->setSongs({});
    m_similarList->setSongs({});
    m_similarHeader->setVisible(false);
    m_similarList->setVisible(false);
    refreshTrackHeights();
    render();
    detach(loadAsync(token));
}

Task<void> AlbumDetailView::loadAsync(quint64 token)
{
    auto alive = m_alive;
    const QString id = m_albumID.value_or(QString());
    IMusicProvider* provider = AppState::shared().provider();
    if (provider == nullptr) co_return;
    try {
        PlaylistDetail loaded = co_await provider->fetchAlbumDetail(id, CancellationToken::none());
        if (!*alive || token != m_loadToken) co_return;
        m_detail = loaded;
        m_trackList->setSongs(loaded.tracks);
        m_isLoading = false;
        refreshTrackHeights();
        render();
        if (!loaded.tracks.isEmpty()) {
            const Song first = loaded.tracks.first();
            if (first.source == SongSource::Netease) {
                co_await loadSimilarAsync(token, id, first);
            }
        }
    } catch (const MusicException& error) {
        if (!*alive || token != m_loadToken) co_return;
        if (error.isCancelled()) co_return;
        m_errorMessage = error.userFacingMessage();
        m_isLoading = false;
        render();
    } catch (const std::exception& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_errorMessage = MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
        m_isLoading = false;
        render();
    }
}

Task<void> AlbumDetailView::loadSimilarAsync(quint64 token, QString albumID, Song first)
{
    auto alive = m_alive;
    try {
        const QList<Song> loaded
            = co_await socialProvider().fetchSimilarSongs(first.id, 20, CancellationToken::none());
        if (!*alive || token != m_loadToken || m_albumID.value_or(QString()) != albumID) co_return;
        QList<Song> similar;
        for (const Song& song : loaded) {
            if (song.id != first.id) similar.append(song);
        }
        if (similar.isEmpty()) co_return;
        m_similarList->setSongs(similar);
        m_similarHeader->setVisible(true);
        m_similarList->setVisible(true);
        refreshTrackHeights();
    } catch (const MusicException&) {
    } catch (const std::exception&) {
    }
}

void AlbumDetailView::refreshTrackHeights()
{
    m_trackList->setFixedHeight(m_trackList->songs().size() * 52);
    m_similarList->setFixedHeight(m_similarList->songs().size() * 52);
}

void AlbumDetailView::render()
{
    if (!*m_alive) return;
    if (m_isLoading && !m_detail.has_value()) {
        showStatus(ui::statusPanel(L10n::Common::Loading, true));
        return;
    }
    if (m_errorMessage.has_value()) {
        showStatus(ui::errorPanel(*m_errorMessage, [this] { load(); }));
        return;
    }
    if (!m_detail.has_value()) {
        const std::optional<QString> id = AppState::shared().selectedAlbumID();
        showStatus(id.has_value() && !id->isEmpty() ? ui::statusPanel(L10n::Common::Loading, true)
                                                    : ui::statusPanel(QStringLiteral("专辑不存在或已下架"), false));
        return;
    }

    m_statusHost->setVisible(false);
    m_headerHost->setVisible(true);
    m_bodyScroll->setVisible(true);
    renderHeader();
}

void AlbumDetailView::showStatus(QWidget* status)
{
    clearLayout(m_statusLayout);
    if (status != nullptr) m_statusLayout->addWidget(status);
    m_statusHost->setVisible(true);
    m_headerHost->setVisible(false);
    m_bodyScroll->setVisible(false);
}

void AlbumDetailView::renderHeader()
{
    clearLayout(m_headerLayout);
    if (!m_detail.has_value()) return;
    m_headerLayout->addWidget(buildHeader());
}

QWidget* AlbumDetailView::buildHeader()
{
    const PlaylistDetail detail = *m_detail;
    const bool isSubscribed = m_isSubscribed.value_or(false);

    auto* header = new QWidget();
    auto* layout = new QHBoxLayout(header);
    layout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Lg);
    layout->setSpacing(CTSpacing::Lg);

    auto* cover = new CoverImage(header);
    cover->setFixedSize(180, 180);
    cover->setCornerRadius(CTRadius::Medium);
    cover->setCoverURL(detail.playlist.coverURL, 360);
    layout->addWidget(cover, 0, Qt::AlignTop);

    auto* info = new QWidget(header);
    auto* infoLayout = new QVBoxLayout(info);
    infoLayout->setContentsMargins(CTSpacing::Lg, 0, 0, 0);
    infoLayout->setSpacing(CTSpacing::Sm);

    auto* name = ui::titleLabel(detail.playlist.name, CTTypography::PageTitle, true);
    name->setWordWrap(true);
    infoLayout->addWidget(name);

    if (detail.playlist.creatorName.has_value() && !detail.playlist.creatorName->isEmpty()) {
        const QString artistName = *detail.playlist.creatorName;
        if (detail.artistID.has_value() && !detail.artistID->isEmpty()) {
            const QString artistID = *detail.artistID;
            infoLayout->addWidget(ui::linkButton(QStringLiteral("歌手：%1").arg(artistName),
                [artistID] { AppState::shared().openArtist(artistID); }), 0, Qt::AlignLeft);
        } else {
            infoLayout->addWidget(
                ui::secondaryLabel(QStringLiteral("歌手：%1").arg(artistName)), 0, Qt::AlignLeft);
        }
    }

    infoLayout->addWidget(ui::secondaryLabel(QStringLiteral("%1 首歌曲").arg(detail.tracks.size())));

    auto* actions = new QWidget(info);
    auto* actionsLayout = new QHBoxLayout(actions);
    actionsLayout->setContentsMargins(0, 0, 0, 0);
    actionsLayout->setSpacing(CTSpacing::Md);

    const QList<Song> tracks = detail.tracks;
    auto* playAll = ui::accentButton(QStringLiteral("播放全部"));
    playAll->setEnabled(!tracks.isEmpty());
    connect(playAll, &QPushButton::clicked, this, [tracks] {
        PlayerController::shared().playSongs(tracks, 0);
    });
    actionsLayout->addWidget(playAll);

    auto* insertNext = ui::ghostButton(QStringLiteral("下一首播放"));
    insertNext->setEnabled(!tracks.isEmpty());
    connect(insertNext, &QPushButton::clicked, this, [tracks] {
        PlayerController::shared().insertNext(tracks);
    });
    actionsLayout->addWidget(insertNext);

    if (AppState::shared().canPerformWrite()) {
        auto* subscribe = ui::ghostButton(isSubscribed ? QStringLiteral("取消收藏")
                                                       : QStringLiteral("收藏专辑"));
        subscribe->setEnabled(!m_isSubscribing);
        connect(subscribe, &QPushButton::clicked, this, [this, isSubscribed] {
            detach(subscribeAsync(!isSubscribed, m_loadToken));
        });
        actionsLayout->addWidget(subscribe);
    }
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

Task<void> AlbumDetailView::subscribeAsync(bool subscribe, quint64 token)
{
    auto alive = m_alive;
    const std::optional<QString> id = m_albumID;
    if (!id.has_value() || m_isSubscribing) co_return;
    m_isSubscribing = true;
    renderHeader();
    bool ok = true;
    try {
        co_await socialProvider().subscribeAlbum(*id, subscribe, CancellationToken::none());
    } catch (const MusicException& error) {
        ok = false;
        if (*alive && token == m_loadToken) {
            AppState::shared().publishWriteError(error);
            m_actionError = error.userFacingMessage();
        }
    } catch (const std::exception& error) {
        ok = false;
        if (*alive && token == m_loadToken) {
            m_actionError = MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
        }
    }
    if (!*alive) co_return;
    m_isSubscribing = false;
    if (ok && token == m_loadToken) {
        m_isSubscribed = subscribe;
        m_actionError.reset();
    }
    if (token == m_loadToken) renderHeader();
    co_return;
}

CT_REGISTER_PAGE(Page::AlbumDetail, AlbumDetailView);

} // namespace ct
