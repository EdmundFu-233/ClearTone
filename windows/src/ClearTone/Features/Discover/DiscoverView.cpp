#include "Features/Discover/DiscoverView.h"

#include "App/AppState.h"
#include "Core/Logging/CTLog.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Playback/PlayerController.h"
#include "Providers/Netease/NeteaseProvider.h"
#include "Providers/Netease/NeteaseSocialProvider.h"

#include <QGridLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QMouseEvent>
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

void setHost(QVBoxLayout* layout, QWidget* content)
{
    while (QLayoutItem* item = layout->takeAt(0)) {
        if (QWidget* widget = item->widget()) {
            if (widget != content) widget->deleteLater();
        }
        delete item;
    }
    if (content != nullptr) layout->addWidget(content);
}

bool isNumericID(const QString& value)
{
    if (value.isEmpty()) return false;
    for (const QChar character : value) {
        if (!character.isDigit()) return false;
    }
    return true;
}

QString unknownUserMessage(const std::exception& error)
{
    return MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
}

QWidget* buildArtistLinks(const QList<Artist>& artists)
{
    auto* row = new QWidget();
    auto* layout = new QHBoxLayout(row);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    if (artists.isEmpty()) {
        layout->addWidget(ui::secondaryLabel(QStringLiteral("未知歌手")));
        return row;
    }
    for (int index = 0; index < artists.size(); ++index) {
        if (index > 0) layout->addWidget(ui::secondaryLabel(QStringLiteral(" / ")));
        const Artist& artist = artists[index];
        if (isNumericID(artist.id)) {
            const QString id = artist.id;
            layout->addWidget(ui::linkButton(artist.name, [id] { AppState::shared().openArtist(id); }));
        } else {
            layout->addWidget(ui::secondaryLabel(artist.name));
        }
    }
    return row;
}

QWidget* cardGrid(const QList<QWidget*>& cards, int columns)
{
    auto* container = new QWidget();
    auto* grid = new QGridLayout(container);
    grid->setContentsMargins(0, 0, 0, 0);
    grid->setHorizontalSpacing(CTSpacing::Lg);
    grid->setVerticalSpacing(CTSpacing::Lg);
    for (int index = 0; index < cards.size(); ++index) {
        grid->addWidget(cards[index], index / columns, index % columns, Qt::AlignTop | Qt::AlignLeft);
    }
    grid->setColumnStretch(columns, 1);
    return container;
}

QWidget* buildPlaylistGrid(const QList<Playlist>& playlists, bool isLoading,
    const std::optional<QString>& error, const QString& emptyText, std::function<void()> retry)
{
    if (isLoading && playlists.isEmpty()) return ui::statusPanel(QStringLiteral("加载中…"), true);
    if (error.has_value() && playlists.isEmpty()) {
        return ui::errorPanel(*error, std::move(retry));
    }
    if (playlists.isEmpty()) return ui::statusPanel(emptyText, false);
    QList<QWidget*> cards;
    for (const Playlist& playlist : playlists) {
        cards.append(ui::playlistCard(playlist, [](const Playlist& item) {
            AppState::shared().openPlaylist(item.id);
        }));
    }
    return cardGrid(cards, 4);
}

QWidget* buildAlbumGrid(const QList<Album>& albums, bool isLoading,
    const std::optional<QString>& error, const QString& emptyText, std::function<void()> retry)
{
    if (isLoading && albums.isEmpty()) return ui::statusPanel(QStringLiteral("加载中…"), true);
    if (error.has_value() && albums.isEmpty()) {
        return ui::errorPanel(*error, std::move(retry));
    }
    if (albums.isEmpty()) return ui::statusPanel(emptyText, false);
    QList<QWidget*> cards;
    for (const Album& album : albums) {
        cards.append(ui::albumCard(album, [](const Album& item) {
            AppState::shared().openAlbum(item.id);
        }));
    }
    return cardGrid(cards, 4);
}

QWidget* buildRadioCard(const RadioStation& radio)
{
    auto* card = new ui::CardButton();
    card->setFixedWidth(160);
    auto* layout = new QVBoxLayout(card);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(6);

    auto* cover = new CoverImage(card);
    cover->setFixedSize(160, 160);
    cover->setCornerRadius(CTRadius::Medium);
    cover->setCoverURL(radio.coverURL, 320);
    layout->addWidget(cover, 0, Qt::AlignHCenter);

    auto* name = ui::titleLabel(radio.name, CTTypography::Body, true);
    name->setMaximumWidth(160);
    layout->addWidget(name);

    QStringList parts;
    if (radio.creatorName.has_value() && !radio.creatorName->isEmpty()) {
        parts.append(*radio.creatorName);
    }
    if (radio.programCount > 0) parts.append(QStringLiteral("%1 期").arg(radio.programCount));
    layout->addWidget(ui::secondaryLabel(
        parts.isEmpty() ? QStringLiteral("电台") : parts.join(QStringLiteral(" · "))));

    const QString id = radio.id;
    card->onClicked = [id] { AppState::shared().openRadio(id); };
    return card;
}

class SongCard : public QFrame {
public:
    explicit SongCard(QWidget* parent = nullptr)
        : QFrame(parent)
    {
        setObjectName(QStringLiteral("ctSongCard"));
        setCursor(Qt::PointingHandCursor);
        setStyleSheet(QStringLiteral("QFrame#ctSongCard { background: transparent; border-radius: 8px; }"));
    }

    std::function<void()> onDoubleClicked;

protected:
    void mouseDoubleClickEvent(QMouseEvent* event) override
    {
        if (event->button() == Qt::LeftButton && onDoubleClicked) onDoubleClicked();
        QFrame::mouseDoubleClickEvent(event);
    }

    void enterEvent(QEnterEvent* event) override
    {
        setStyleSheet(QStringLiteral("QFrame#ctSongCard { background: %1; border-radius: 8px; }")
                          .arg(CTColors::overlay().name()));
        QFrame::enterEvent(event);
    }

    void leaveEvent(QEvent* event) override
    {
        setStyleSheet(QStringLiteral("QFrame#ctSongCard { background: transparent; border-radius: 8px; }"));
        QFrame::leaveEvent(event);
    }
};

} // namespace

DiscoverView::DiscoverView(QWidget* parent)
    : QWidget(parent)
{
    setObjectName(QStringLiteral("ctDiscoverView"));
    setStyleSheet(QStringLiteral("QWidget#ctDiscoverView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    auto* titleStack = new QWidget(this);
    auto* titleLayout = new QVBoxLayout(titleStack);
    titleLayout->setContentsMargins(0, 0, 0, 0);
    titleLayout->setSpacing(CTSpacing::Xs);
    titleLayout->addWidget(ui::titleLabel(QStringLiteral("发现音乐"), CTTypography::PageTitle, true));
    titleLayout->addWidget(ui::secondaryLabel(QStringLiteral("为今天，找到合适的旋律。")));

    auto* header = new QWidget(this);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, 0);
    headerLayout->addWidget(titleStack);
    headerLayout->addStretch(1);
    root->addWidget(header);

    m_dailyPlayAll = ui::ghostButton(QStringLiteral("播放全部"));
    m_newSongsPlayAll = ui::ghostButton(QStringLiteral("播放全部"));
    connect(m_dailyPlayAll, &QPushButton::clicked, this, [this] {
        if (!m_dailySongs.isEmpty()) PlayerController::shared().playSongs(m_dailySongs, 0);
    });
    connect(m_newSongsPlayAll, &QPushButton::clicked, this, [this] {
        if (!m_newSongs.isEmpty()) PlayerController::shared().playSongs(m_newSongs, 0);
    });

    auto makeHost = [](QWidget*& host, QVBoxLayout*& layout) {
        host = new QWidget();
        layout = new QVBoxLayout(host);
        layout->setContentsMargins(0, 0, 0, 0);
        layout->setSpacing(0);
    };
    makeHost(m_dailyHost, m_dailyLayout);
    makeHost(m_playlistsHost, m_playlistsLayout);
    makeHost(m_dailyPlaylistsHost, m_dailyPlaylistsLayout);
    makeHost(m_radiosHost, m_radiosLayout);
    makeHost(m_newSongsHost, m_newSongsLayout);
    makeHost(m_newAlbumsHost, m_newAlbumsLayout);

    auto buildSection = [](const QString& title, QWidget* host, QWidget* trailing) {
        auto* section = new QWidget();
        auto* layout = new QVBoxLayout(section);
        layout->setContentsMargins(0, 0, 0, 0);
        layout->setSpacing(CTSpacing::Md);
        layout->addWidget(ui::headerRow(title, trailing));
        layout->addWidget(host);
        return section;
    };

    auto* body = new QWidget(this);
    auto* bodyLayout = new QVBoxLayout(body);
    bodyLayout->setContentsMargins(CTSpacing::Xl, CTSpacing::Lg, CTSpacing::Xl, CTSpacing::Xl);
    bodyLayout->setSpacing(CTSpacing::Xl);
    bodyLayout->addWidget(buildSection(QStringLiteral("每日推荐"), m_dailyHost, m_dailyPlayAll));
    bodyLayout->addWidget(buildSection(QStringLiteral("推荐歌单"), m_playlistsHost, nullptr));
    bodyLayout->addWidget(
        buildSection(QStringLiteral("每日推荐歌单"), m_dailyPlaylistsHost, nullptr));
    bodyLayout->addWidget(buildSection(QStringLiteral("推荐电台"), m_radiosHost, nullptr));
    bodyLayout->addWidget(
        buildSection(QStringLiteral("新歌速递"), m_newSongsHost, m_newSongsPlayAll));
    bodyLayout->addWidget(buildSection(QStringLiteral("新专辑"), m_newAlbumsHost, nullptr));
    bodyLayout->addStretch(1);
    root->addWidget(ui::scrollWrapper(body), 1);

    m_lastDataContextKey = AppState::shared().dataContextKey();
    m_appObserver = AppState::shared().changed.subscribe([this] { scheduleAppChange(); });
    m_contextObserver = AppState::shared().dataContextChanged.subscribe([this] { scheduleAppChange(); });
    renderAll();
}

DiscoverView::~DiscoverView()
{
    *m_alive = false;
    AppState::shared().changed.unsubscribe(m_appObserver);
    AppState::shared().dataContextChanged.unsubscribe(m_contextObserver);
}

void DiscoverView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    loadAll();
}

void DiscoverView::scheduleAppChange()
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

void DiscoverView::handleAppChange()
{
    const QString key = AppState::shared().dataContextKey();
    if (key == m_lastDataContextKey) return;
    m_lastDataContextKey = key;
    loadAll();
}

void DiscoverView::loadAll()
{
    const quint64 token = ++m_loadToken;
    detach(loadDailySongsAsync(token));
    detach(loadPlaylistsAsync(token));
    detach(loadDailyPlaylistsAsync(token));
    detach(loadRadiosAsync(token));
    detach(loadNewSongsAsync(token));
    detach(loadNewAlbumsAsync(token));
}

Task<void> DiscoverView::loadDailySongsAsync(quint64 token)
{
    auto alive = m_alive;
    m_dailyLoading = true;
    m_dailyError.reset();
    renderDaily();
    if (!AppState::shared().isLoggedIn()) {
        m_dailySongs.clear();
        m_dailyLoading = false;
        renderDaily();
        co_return;
    }
    if (AppState::shared().provider() == nullptr) {
        m_dailyLoading = false;
        renderDaily();
        co_return;
    }
    try {
        const QList<Song> loaded = co_await AppState::shared().provider()->fetchDailyRecommendSongs(
            CancellationToken::none());
        if (!*alive || token != m_loadToken) co_return;
        m_dailySongs = loaded;
    } catch (const MusicException& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_dailySongs.clear();
        m_dailyError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_dailySongs.clear();
        m_dailyError = unknownUserMessage(error);
    }
    if (!*alive || token != m_loadToken) co_return;
    m_dailyLoading = false;
    renderDaily();
    co_return;
}

Task<void> DiscoverView::loadPlaylistsAsync(quint64 token)
{
    auto alive = m_alive;
    m_playlistsLoading = true;
    m_playlistsError.reset();
    renderPlaylists();
    if (AppState::shared().provider() == nullptr) {
        m_playlistsLoading = false;
        renderPlaylists();
        co_return;
    }
    try {
        const QList<Playlist> loaded = co_await AppState::shared().provider()->fetchRecommendPlaylists(
            CancellationToken::none());
        if (!*alive || token != m_loadToken) co_return;
        m_playlists = loaded;
    } catch (const MusicException& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_playlists.clear();
        m_playlistsError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_playlists.clear();
        m_playlistsError = unknownUserMessage(error);
    }
    if (!*alive || token != m_loadToken) co_return;
    m_playlistsLoading = false;
    renderPlaylists();
    co_return;
}

Task<void> DiscoverView::loadDailyPlaylistsAsync(quint64 token)
{
    auto alive = m_alive;
    m_dailyPlaylistsLoading = true;
    m_dailyPlaylistsError.reset();
    renderDailyPlaylists();
    if (!AppState::shared().isLoggedIn()) {
        m_dailyPlaylists.clear();
        m_dailyPlaylistsLoading = false;
        renderDailyPlaylists();
        co_return;
    }
    try {
        const QList<Playlist> loaded = co_await socialProvider().fetchDailyRecommendPlaylists(
            CancellationToken::none());
        if (!*alive || token != m_loadToken) co_return;
        m_dailyPlaylists = loaded;
    } catch (const MusicException& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_dailyPlaylists.clear();
        m_dailyPlaylistsError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_dailyPlaylists.clear();
        m_dailyPlaylistsError = unknownUserMessage(error);
    }
    if (!*alive || token != m_loadToken) co_return;
    m_dailyPlaylistsLoading = false;
    renderDailyPlaylists();
    co_return;
}

Task<void> DiscoverView::loadRadiosAsync(quint64 token)
{
    auto alive = m_alive;
    m_radiosLoading = true;
    m_radiosError.reset();
    renderRadios();
    try {
        QList<RadioStation> loaded
            = co_await NeteaseProvider::shared().fetchRecommendedRadios(30, CancellationToken::none());
        if (!*alive || token != m_loadToken) co_return;
        if (loaded.isEmpty()) {
            loaded = co_await NeteaseProvider::shared().fetchHotRadios(
                std::nullopt, 30, CancellationToken::none());
            if (!*alive || token != m_loadToken) co_return;
        }
        m_radios = loaded;
    } catch (const MusicException& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_radios.clear();
        m_radiosError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_radios.clear();
        m_radiosError = unknownUserMessage(error);
    }
    if (!*alive || token != m_loadToken) co_return;
    m_radiosLoading = false;
    renderRadios();
    co_return;
}

Task<void> DiscoverView::loadNewSongsAsync(quint64 token)
{
    auto alive = m_alive;
    m_newSongsLoading = true;
    m_newSongsError.reset();
    renderNewSongs();
    try {
        const QList<Song> loaded = co_await socialProvider().fetchNewSongs(
            30, CancellationToken::none());
        if (!*alive || token != m_loadToken) co_return;
        m_newSongs = loaded;
    } catch (const MusicException& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_newSongs.clear();
        m_newSongsError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_newSongs.clear();
        m_newSongsError = unknownUserMessage(error);
    }
    if (!*alive || token != m_loadToken) co_return;
    m_newSongsLoading = false;
    renderNewSongs();
    co_return;
}

Task<void> DiscoverView::loadNewAlbumsAsync(quint64 token)
{
    auto alive = m_alive;
    m_newAlbumsLoading = true;
    m_newAlbumsError.reset();
    renderNewAlbums();
    try {
        const QList<Album> loaded = co_await socialProvider().fetchNewAlbums(
            30, CancellationToken::none());
        if (!*alive || token != m_loadToken) co_return;
        m_newAlbums = loaded;
    } catch (const MusicException& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_newAlbums.clear();
        m_newAlbumsError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || token != m_loadToken) co_return;
        m_newAlbums.clear();
        m_newAlbumsError = unknownUserMessage(error);
    }
    if (!*alive || token != m_loadToken) co_return;
    m_newAlbumsLoading = false;
    renderNewAlbums();
    co_return;
}

Task<void> DiscoverView::dislikeDailyAsync(Song song)
{
    auto alive = m_alive;
    if (!AppState::shared().canPerformWrite()) co_return;
    if (m_dailyDislikesInFlight.contains(song.id)) co_return;
    m_dailyDislikesInFlight.insert(song.id);
    const quint64 token = m_loadToken;
    renderDaily();
    try {
        const std::optional<Song> replacement
            = co_await socialProvider().dislikeDailyRecommend(song.id, CancellationToken::none());
        if (*alive && token == m_loadToken) {
            int index = -1;
            for (int i = 0; i < m_dailySongs.size(); ++i) {
                if (m_dailySongs[i].id == song.id) {
                    index = i;
                    break;
                }
            }
            if (index >= 0) {
                if (replacement.has_value()) {
                    m_dailySongs[index] = *replacement;
                } else {
                    m_dailySongs.removeAt(index);
                }
            }
        }
    } catch (const MusicException& error) {
        if (*alive) {
            CTLog::general().error(
                QStringLiteral("反馈不喜欢失败: %1").arg(CTLog::sanitize(error.message())));
        }
    } catch (const std::exception& error) {
        if (*alive) {
            CTLog::general().error(QStringLiteral("反馈不喜欢失败: %1")
                                       .arg(CTLog::sanitize(QString::fromUtf8(error.what()))));
        }
    }
    if (!*alive) co_return;
    m_dailyDislikesInFlight.remove(song.id);
    if (token == m_loadToken) renderDaily();
    co_return;
}

void DiscoverView::renderAll()
{
    renderDaily();
    renderPlaylists();
    renderDailyPlaylists();
    renderRadios();
    renderNewSongs();
    renderNewAlbums();
}

void DiscoverView::renderDaily()
{
    m_dailyPlayAll->setEnabled(!m_dailySongs.isEmpty());
    m_dailyPlayAll->setText(m_dailySongs.isEmpty()
            ? QStringLiteral("播放全部")
            : QStringLiteral("播放全部 (%1)").arg(m_dailySongs.size()));

    if (!AppState::shared().isLoggedIn()) {
        setHost(m_dailyLayout, ui::statusPanel(QStringLiteral("登录后查看每日推荐"), false));
        return;
    }
    if (m_dailyLoading && m_dailySongs.isEmpty()) {
        setHost(m_dailyLayout, ui::statusPanel(QStringLiteral("加载中…"), true));
        return;
    }
    if (m_dailyError.has_value() && m_dailySongs.isEmpty()) {
        setHost(m_dailyLayout, ui::errorPanel(*m_dailyError,
                                     [this] { detach(loadDailySongsAsync(m_loadToken)); }));
        return;
    }
    if (m_dailySongs.isEmpty()) {
        setHost(m_dailyLayout, ui::statusPanel(QStringLiteral("暂无每日推荐"), false));
        return;
    }
    setHost(m_dailyLayout, buildSongStrip(m_dailySongs, true));
}

void DiscoverView::renderPlaylists()
{
    setHost(m_playlistsLayout,
        buildPlaylistGrid(m_playlists, m_playlistsLoading, m_playlistsError,
            QStringLiteral("暂无推荐歌单"), [this] { detach(loadPlaylistsAsync(m_loadToken)); }));
}

void DiscoverView::renderDailyPlaylists()
{
    if (!AppState::shared().isLoggedIn()) {
        setHost(m_dailyPlaylistsLayout,
            ui::statusPanel(QStringLiteral("登录后查看每日推荐歌单"), false));
        return;
    }
    setHost(m_dailyPlaylistsLayout,
        buildPlaylistGrid(m_dailyPlaylists, m_dailyPlaylistsLoading, m_dailyPlaylistsError,
            QStringLiteral("暂无每日推荐歌单"),
            [this] { detach(loadDailyPlaylistsAsync(m_loadToken)); }));
}

void DiscoverView::renderRadios()
{
    if (m_radiosLoading && m_radios.isEmpty()) {
        setHost(m_radiosLayout, ui::statusPanel(QStringLiteral("加载中…"), true));
        return;
    }
    if (m_radiosError.has_value() && m_radios.isEmpty()) {
        setHost(m_radiosLayout,
            ui::errorPanel(*m_radiosError, [this] { detach(loadRadiosAsync(m_loadToken)); }));
        return;
    }
    if (m_radios.isEmpty()) {
        setHost(m_radiosLayout, ui::statusPanel(QStringLiteral("暂无推荐电台"), false));
        return;
    }
    QList<QWidget*> cards;
    for (const RadioStation& radio : std::as_const(m_radios)) {
        cards.append(buildRadioCard(radio));
    }
    setHost(m_radiosLayout, cardGrid(cards, 4));
}

void DiscoverView::renderNewSongs()
{
    m_newSongsPlayAll->setEnabled(!m_newSongs.isEmpty());
    m_newSongsPlayAll->setText(m_newSongs.isEmpty()
            ? QStringLiteral("播放全部")
            : QStringLiteral("播放全部 (%1)").arg(m_newSongs.size()));

    if (m_newSongsLoading && m_newSongs.isEmpty()) {
        setHost(m_newSongsLayout, ui::statusPanel(QStringLiteral("加载中…"), true));
        return;
    }
    if (m_newSongsError.has_value() && m_newSongs.isEmpty()) {
        setHost(m_newSongsLayout,
            ui::errorPanel(*m_newSongsError, [this] { detach(loadNewSongsAsync(m_loadToken)); }));
        return;
    }
    if (m_newSongs.isEmpty()) {
        setHost(m_newSongsLayout, ui::statusPanel(QStringLiteral("暂无新歌"), false));
        return;
    }
    setHost(m_newSongsLayout, buildSongStrip(m_newSongs, false));
}

void DiscoverView::renderNewAlbums()
{
    setHost(m_newAlbumsLayout,
        buildAlbumGrid(m_newAlbums, m_newAlbumsLoading, m_newAlbumsError,
            QStringLiteral("暂无新专辑"), [this] { detach(loadNewAlbumsAsync(m_loadToken)); }));
}

QWidget* DiscoverView::buildSongStrip(const QList<Song>& songs, bool allowDislike)
{
    auto* panel = new QWidget();
    auto* layout = new QHBoxLayout(panel);
    layout->setContentsMargins(0, 0, 0, CTSpacing::Sm);
    layout->setSpacing(CTSpacing::Md);

    for (const Song& song : songs) {
        auto* card = new SongCard();
        card->setFixedWidth(158);
        auto* cardLayout = new QVBoxLayout(card);
        cardLayout->setContentsMargins(CTSpacing::Xs, CTSpacing::Xs, CTSpacing::Xs, CTSpacing::Xs);
        cardLayout->setSpacing(CTSpacing::Sm);

        auto* cover = new CoverImage(card);
        cover->setFixedSize(150, 150);
        cover->setCornerRadius(CTRadius::Medium);
        cover->setCoverURL(song.coverURL, 300);
        cardLayout->addWidget(cover, 0, Qt::AlignHCenter);

        auto* title = ui::titleLabel(song.title, CTTypography::Body, true);
        title->setMaximumWidth(150);
        cardLayout->addWidget(title);

        cardLayout->addWidget(buildArtistLinks(song.artists));

        auto* meta = new QWidget(card);
        auto* metaLayout = new QHBoxLayout(meta);
        metaLayout->setContentsMargins(0, 0, 0, 0);
        metaLayout->setSpacing(CTSpacing::Sm);
        metaLayout->addWidget(ui::secondaryLabel(CTFormatting::time(song.duration)));
        if (!song.isPlayable) {
            metaLayout->addWidget(ui::secondaryLabel(
                song.unavailableReason.value_or(QStringLiteral("不可播放"))));
        }
        if (allowDislike && song.source == SongSource::Netease) {
            auto* dislike = ui::linkButton(QStringLiteral("✕"), [this, song] { detach(dislikeDailyAsync(song)); });
            dislike->setToolTip(QStringLiteral("不喜欢这首歌"));
            dislike->setEnabled(AppState::shared().canPerformWrite()
                && !m_dailyDislikesInFlight.contains(song.id));
            metaLayout->addWidget(dislike);
        }
        metaLayout->addStretch(1);
        cardLayout->addWidget(meta);

        if (song.isPlayable) {
            const Song copy = song;
            card->onDoubleClicked = [copy] { PlayerController::shared().playSong(copy); };
        }
        layout->addWidget(card, 0, Qt::AlignTop);
    }
    layout->addStretch(1);

    auto* area = new QScrollArea();
    area->setFrameShape(QFrame::NoFrame);
    area->setWidgetResizable(true);
    area->setHorizontalScrollBarPolicy(Qt::ScrollBarAsNeeded);
    area->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    area->setWidget(panel);
    area->setStyleSheet(QStringLiteral("QScrollArea { background: transparent; }"));
    return area;
}

CT_REGISTER_PAGE(Page::Discover, DiscoverView);

} // namespace ct
