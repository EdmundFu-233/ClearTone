#include "Features/Playlist/PlaylistDetailView.h"

#include "App/AppState.h"
#include "Core/Models/MusicSocialProvider.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "DesignSystem/FlowLayout.h"
#include "DesignSystem/L10n.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Playback/PlayerController.h"
#include "Providers/Netease/NeteaseProvider.h"
#include "Providers/Netease/NeteaseSocialProvider.h"

#include <QContextMenuEvent>
#include <QDialog>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMenu>
#include <QProgressBar>
#include <QPushButton>
#include <QSet>
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

PlaylistDetailView::PlaylistDetailView(QWidget* parent)
    : QWidget(parent)
{
    setObjectName(QStringLiteral("ctPlaylistDetailView"));
    setStyleSheet(QStringLiteral("QWidget#ctPlaylistDetailView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    m_headerHost = new QWidget(this);
    m_headerLayout = new QVBoxLayout(m_headerHost);
    m_headerLayout->setContentsMargins(0, 0, 0, 0);
    m_headerLayout->setSpacing(0);
    root->addWidget(m_headerHost);

    m_trackList = new SongListView(this);
    m_trackList->listWidget()->viewport()->installEventFilter(this);
    root->addWidget(m_trackList, 1);

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

PlaylistDetailView::~PlaylistDetailView()
{
    *m_alive = false;
    if (m_loadCts) m_loadCts->cancel();
    if (m_streamCts) m_streamCts->cancel();
    AppState::shared().changed.unsubscribe(m_appObserver);
}

void PlaylistDetailView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    m_isAttached = true;
    load();
}

void PlaylistDetailView::hideEvent(QHideEvent* event)
{
    QWidget::hideEvent(event);
    m_isAttached = false;
    if (m_loadCts) m_loadCts->cancel();
    if (m_streamCts) m_streamCts->cancel();
    m_streamCts = nullptr;
}

bool PlaylistDetailView::eventFilter(QObject* watched, QEvent* event)
{
    if (watched == m_trackList->listWidget()->viewport() && event->type() == QEvent::ContextMenu
        && m_isOwned) {
        auto* contextEvent = static_cast<QContextMenuEvent*>(event);
        QListWidgetItem* item = m_trackList->listWidget()->itemAt(contextEvent->pos());
        if (item != nullptr) {
            const int row = item->data(Qt::UserRole).toInt();
            showOwnedTrackMenu(contextEvent->globalPos(), row);
            return true;
        }
    }
    return QWidget::eventFilter(watched, event);
}

void PlaylistDetailView::showOwnedTrackMenu(const QPoint& position, int row)
{
    const QList<Song> songs = m_trackList->songs();
    if (row < 0 || row >= songs.size()) return;
    const Song song = songs.at(row);
    AppState& app = AppState::shared();

    QMenu menu(this);
    menu.addAction(QStringLiteral("立即播放"),
        [songs, row] { PlayerController::shared().playSongs(songs, row); });
    menu.addAction(QStringLiteral("下一首播放"),
        [song] { PlayerController::shared().insertNext(song); });
    menu.addAction(QStringLiteral("添加到队列"),
        [song] { PlayerController::shared().appendToQueue(song); });
    menu.addAction(app.isLiked(song.id) ? QStringLiteral("取消喜欢") : QStringLiteral("喜欢"),
        [&app, song] { detach(app.toggleLike(song)); });
    if (app.isLoggedIn() && !app.userPlaylists().isEmpty()) {
        QMenu* addTo = menu.addMenu(QStringLiteral("添加到歌单"));
        const QList<Playlist> playlists = app.userPlaylists();
        for (const Playlist& playlist : playlists) {
            if (addTo->actions().size() >= 50) break;
            const Playlist captured = playlist;
            addTo->addAction(captured.name, [&app, captured, song] {
                detach(app.modifyPlaylist(captured, {song.id}, true));
            });
        }
    }
    if (song.album.has_value() && !song.album->id.isEmpty()) {
        menu.addAction(QStringLiteral("打开专辑"), [&app, song] { app.openAlbum(song.album->id); });
    }
    if (!song.artists.isEmpty()) {
        menu.addAction(QStringLiteral("打开歌手"),
            [&app, song] { app.openArtist(song.artists.first().id); });
    }
    if (song.source == SongSource::Netease) {
        menu.addAction(QStringLiteral("从这个歌单移除"), [this, song] { showRemoveDialog(song); });
    }
    menu.exec(position);
}

void PlaylistDetailView::scheduleAppChange()
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

void PlaylistDetailView::handleAppChange()
{
    if (!*m_alive) return;
    const AppState& app = AppState::shared();
    const QString key = app.dataContextKey();
    const bool contextChanged = key != m_lastDataContextKey;
    if (contextChanged) m_lastDataContextKey = key;

    const std::optional<QString> selected = app.selectedPlaylistID();
    if (selected != m_playlistID) {
        if (m_isAttached) load();
        return;
    }
    if (contextChanged && m_isAttached) {
        load();
        return;
    }
    const bool owned = isOwned();
    if (owned != m_isOwned) {
        m_isOwned = owned;
        if (m_detail.has_value()) renderHeader();
    }
}

bool PlaylistDetailView::isOwned() const
{
    if (!m_playlistID.has_value()) return false;
    const QList<Playlist>& playlists = AppState::shared().userPlaylists();
    for (const Playlist& playlist : playlists) {
        if (playlist.id == *m_playlistID) return true;
    }
    return false;
}

void PlaylistDetailView::load()
{
    const std::optional<QString> id = AppState::shared().selectedPlaylistID();
    if (!id.has_value() || id->isEmpty()) {
        m_playlistID.reset();
        m_detail.reset();
        m_isLoading = false;
        m_errorMessage.reset();
        m_isSubscribed.reset();
        m_trackList->setSongs({});
        render();
        return;
    }

    if (m_loadCts) m_loadCts->cancel();
    if (m_streamCts) m_streamCts->cancel();
    m_loadCts = std::make_shared<CancellationTokenSource>();
    m_streamCts = nullptr;
    const quint64 token = ++m_loadToken;
    m_playlistID = id;
    m_isLoading = true;
    m_errorMessage.reset();
    m_detail.reset();
    m_isSubscribed.reset();
    m_trackList->setSongs({});
    render();
    detach(loadAsync(token));
}

Task<void> PlaylistDetailView::loadAsync(quint64 token)
{
    auto alive = m_alive;
    auto cts = m_loadCts;
    const QString id = m_playlistID.value_or(QString());
    IMusicProvider* provider = AppState::shared().provider();
    if (provider == nullptr || !cts) co_return;
    auto* netease = dynamic_cast<NeteaseProvider*>(provider);
    try {
        std::optional<QList<Song>> cached;
        if (netease != nullptr) cached = netease->cachedPlaylistTracks(id);

        PlaylistDetail loaded = co_await provider->fetchPlaylistDetail(id, cts->token());
        if (!*alive || token != m_loadToken) co_return;

        if (cached.has_value()) {
            loaded.tracks = *cached;
            m_detail = loaded;
            m_trackList->setSongs(loaded.tracks);
            m_isLoading = false;
            render();
            co_return;
        }

        m_detail = loaded;
        m_trackList->setSongs(loaded.tracks);
        m_isLoading = false;
        render();

        if (loaded.totalTrackCount <= loaded.tracks.size() || loaded.totalTrackCount <= 0) co_return;
        if (netease == nullptr) {
            co_await fetchRemainingAsync(id, loaded.totalTrackCount, token);
            co_return;
        }
        co_await streamAsync(id, loaded.totalTrackCount, token);
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

Task<void> PlaylistDetailView::streamAsync(QString playlistID, int totalCount, quint64 token)
{
    auto alive = m_alive;
    auto* netease = dynamic_cast<NeteaseProvider*>(AppState::shared().provider());
    if (netease == nullptr) co_return;

    auto streamCts = std::make_shared<CancellationTokenSource>();
    m_streamCts = streamCts;
    QSet<QString> seen;
    for (const Song& song : m_trackList->songs()) seen.insert(song.id);

    bool streamFailed = false;
    try {
        Awaitable<Unit> streamAwaitable;
        streamAwaitable.starter = [&](Callback<Unit> done) {
            netease->streamPlaylistTracks(playlistID, totalCount, 100, 4, streamCts->token(),
                [this, alive, token, seen](Result<QList<Song>> page) mutable {
                    if (!*alive || token != m_loadToken || page.isFailure()) return;
                    QList<Song> songs = m_trackList->songs();
                    bool changed = false;
                    for (const Song& song : page.value()) {
                        if (seen.contains(song.id)) continue;
                        seen.insert(song.id);
                        songs.append(song);
                        changed = true;
                    }
                    if (!changed) return;
                    m_trackList->setSongs(songs);
                    renderHeader();
                },
                std::move(done));
        };
        co_await streamAwaitable;
    } catch (const MusicException& error) {
        if (!*alive || token != m_loadToken) co_return;
        if (error.isCancelled()) co_return;
        streamFailed = true;
    } catch (const std::exception&) {
        streamFailed = true;
    }
    if (*alive && m_streamCts == streamCts) m_streamCts = nullptr;
    if (streamFailed) co_await fetchRemainingAsync(playlistID, totalCount, token);
}

Task<void> PlaylistDetailView::fetchRemainingAsync(QString playlistID, int totalCount, quint64 token)
{
    auto alive = m_alive;
    IMusicProvider* provider = AppState::shared().provider();
    if (provider == nullptr) co_return;
    const int pageSize = 100;
    const int pageCount = qMax(1, (totalCount + pageSize - 1) / pageSize);
    QSet<QString> seen;
    for (const Song& song : m_trackList->songs()) seen.insert(song.id);

    for (int page = 1; page <= pageCount; ++page) {
        auto cts = m_loadCts;
        if (!cts || cts->isCancellationRequested()) co_return;
        QList<Song> batch;
        try {
            batch = co_await provider->fetchPlaylistTracks(playlistID, page, pageSize, cts->token());
        } catch (const MusicException& error) {
            if (!*alive || token != m_loadToken) co_return;
            if (error.isCancelled()) co_return;
            m_errorMessage = error.userFacingMessage();
            render();
            co_return;
        } catch (const std::exception& error) {
            if (!*alive || token != m_loadToken) co_return;
            m_errorMessage = MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
            render();
            co_return;
        }
        if (!*alive || token != m_loadToken) co_return;
        QList<Song> songs = m_trackList->songs();
        bool changed = false;
        for (const Song& song : batch) {
            if (seen.contains(song.id)) continue;
            seen.insert(song.id);
            songs.append(song);
            changed = true;
        }
        if (changed) {
            m_trackList->setSongs(songs);
            renderHeader();
        }
    }
}

void PlaylistDetailView::render()
{
    if (!*m_alive) return;
    m_isOwned = isOwned();
    if (m_isLoading && !m_detail.has_value()) {
        showStatus(ui::statusPanel(L10n::Common::Loading, true));
        return;
    }
    if (m_errorMessage.has_value()) {
        showStatus(ui::errorPanel(*m_errorMessage, [this] { load(); }));
        return;
    }
    if (!m_detail.has_value()) {
        const std::optional<QString> id = AppState::shared().selectedPlaylistID();
        showStatus(id.has_value() && !id->isEmpty() ? ui::statusPanel(L10n::Common::Loading, true)
                                                    : ui::statusPanel(QStringLiteral("歌单不存在"), false));
        return;
    }

    m_statusHost->setVisible(false);
    m_headerHost->setVisible(true);
    m_trackList->setVisible(true);
    renderHeader();
}

void PlaylistDetailView::showStatus(QWidget* status)
{
    clearLayout(m_statusLayout);
    if (status != nullptr) m_statusLayout->addWidget(status);
    m_statusHost->setVisible(true);
    m_headerHost->setVisible(false);
    m_trackList->setVisible(false);
}

void PlaylistDetailView::renderHeader()
{
    clearLayout(m_headerLayout);
    if (!m_detail.has_value()) return;
    m_headerLayout->addWidget(buildHeader());
}

QWidget* PlaylistDetailView::buildHeader()
{
    const PlaylistDetail detail = *m_detail;
    const Playlist playlist = detail.playlist;
    const bool isSubscribed = m_isSubscribed.value_or(playlist.isSubscribed);

    auto* info = new QWidget();
    auto* infoLayout = new QVBoxLayout(info);
    infoLayout->setContentsMargins(0, 0, 0, 0);
    infoLayout->setSpacing(CTSpacing::Sm);

    auto* name = ui::titleElidedLabel(playlist.name, 26, true);
    infoLayout->addWidget(name);

    if (playlist.creatorName.has_value() && !playlist.creatorName->isEmpty()) {
        auto* creator = ui::secondaryElidedLabel(
            QStringLiteral("创建者：%1").arg(*playlist.creatorName));
        creator->setMaximumWidth(520);
        infoLayout->addWidget(creator);
    }
    if (playlist.descriptionText.has_value() && !playlist.descriptionText->isEmpty()) {
        auto* description = ui::secondaryElidedLabel(*playlist.descriptionText);
        description->setMaximumWidth(520);
        infoLayout->addWidget(description);
    }

    const int trackCount = m_trackList->songs().size();
    auto* countRow = new QWidget(info);
    auto* countLayout = new QHBoxLayout(countRow);
    countLayout->setContentsMargins(0, 0, 0, 0);
    countLayout->setSpacing(CTSpacing::Sm);
    countLayout->addWidget(
        ui::secondaryLabel(QStringLiteral("%1 首歌曲").arg(detail.totalTrackCount)));
    if (trackCount < detail.totalTrackCount) {
        auto* progress = new QProgressBar(countRow);
        progress->setRange(0, 0);
        progress->setTextVisible(false);
        progress->setFixedWidth(60);
        progress->setFixedHeight(4);
        countLayout->addWidget(progress, 0, Qt::AlignVCenter);
        countLayout->addWidget(
            ui::secondaryLabel(QStringLiteral("已加载 %1 首").arg(trackCount)), 0, Qt::AlignVCenter);
    }
    countLayout->addStretch(1);
    infoLayout->addWidget(countRow);

    const QList<Song> songs = m_trackList->songs();
    auto* actions = new QWidget(info);
    auto* actionsLayout = new FlowLayout(actions, CTSpacing::Sm);
    actionsLayout->setContentsMargins(0, 0, 0, 0);
    actionsLayout->setSpacing(CTSpacing::Md);

    auto* playAll = ui::accentButton(QStringLiteral("播放全部"));
    playAll->setEnabled(!songs.isEmpty());
    connect(playAll, &QPushButton::clicked, this, [songs] {
        PlayerController::shared().playSongs(songs, 0);
    });
    actionsLayout->addWidget(playAll);

    auto* append = ui::ghostButton(QStringLiteral("添加到队列"));
    append->setEnabled(!songs.isEmpty());
    connect(append, &QPushButton::clicked, this, [songs] {
        PlayerController::shared().appendToQueue(songs);
    });
    actionsLayout->addWidget(append);

    if (AppState::shared().canPerformWrite()) {
        auto* subscribe = ui::ghostButton(isSubscribed ? QStringLiteral("取消收藏")
                                                       : QStringLiteral("收藏歌单"));
        subscribe->setEnabled(!m_isSubscribing);
        connect(subscribe, &QPushButton::clicked, this, [this, isSubscribed] {
            detach(subscribeAsync(!isSubscribed, m_loadToken));
        });
        actionsLayout->addWidget(subscribe);
    }
    if (m_isOwned) {
        auto* rename = ui::ghostButton(QStringLiteral("重命名"));
        connect(rename, &QPushButton::clicked, this, [this] { showRenameDialog(); });
        actionsLayout->addWidget(rename);

        auto* remove = ui::ghostButton(QStringLiteral("删除歌单"));
        connect(remove, &QPushButton::clicked, this, [this] { showDeleteDialog(); });
        actionsLayout->addWidget(remove);
    }
    infoLayout->addWidget(actions);
    infoLayout->addStretch(1);

    return ui::detailHeader(playlist.coverURL, info);
}

Task<void> PlaylistDetailView::subscribeAsync(bool subscribe, quint64 token)
{
    auto alive = m_alive;
    const std::optional<QString> id = m_playlistID;
    if (!id.has_value()) co_return;
    m_isSubscribing = true;
    renderHeader();
    bool ok = true;
    try {
        co_await socialProvider().subscribePlaylist(*id, subscribe, CancellationToken::none());
    } catch (const MusicException& error) {
        ok = false;
        if (*alive && token == m_loadToken) {
            AppState::shared().publishWriteError(error);
            m_errorMessage = error.userFacingMessage();
        }
    } catch (const std::exception& error) {
        ok = false;
        if (*alive && token == m_loadToken) {
            m_errorMessage = MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
        }
    }
    if (!*alive) co_return;
    m_isSubscribing = false;
    if (ok && token == m_loadToken) {
        m_isSubscribed = subscribe;
        if (m_detail.has_value()) m_detail->playlist.isSubscribed = subscribe;
    }
    render();
    co_return;
}

Task<void> PlaylistDetailView::renameAsync(Playlist playlist, QString name,
    QPointer<QDialog> dialog, QPointer<QLabel> error, QPointer<QPushButton> confirm)
{
    auto alive = m_alive;
    if (confirm) confirm->setEnabled(false);
    if (error) error->setVisible(false);
    bool ok = false;
    try {
        ok = co_await AppState::shared().renamePlaylist(playlist, name);
    } catch (const MusicException&) {
    } catch (const std::exception&) {
    }
    if (!*alive) co_return;
    if (confirm) confirm->setEnabled(true);
    if (ok) {
        if (m_detail.has_value()) {
            m_detail->playlist.name = name;
            renderHeader();
        }
        if (dialog) dialog->accept();
        co_return;
    }
    const QString message = AppState::shared().lastWriteError().isEmpty()
        ? QStringLiteral("操作失败")
        : AppState::shared().lastWriteError();
    if (error) {
        error->setText(message);
        error->setVisible(true);
    }
    co_return;
}

Task<void> PlaylistDetailView::deleteAsync(Playlist playlist, QPointer<QDialog> dialog,
    QPointer<QLabel> error, QPointer<QPushButton> confirm)
{
    auto alive = m_alive;
    if (confirm) confirm->setEnabled(false);
    if (error) error->setVisible(false);
    bool ok = false;
    try {
        ok = co_await AppState::shared().deletePlaylist(playlist);
    } catch (const MusicException&) {
    } catch (const std::exception&) {
    }
    if (!*alive) co_return;
    if (confirm) confirm->setEnabled(true);
    if (ok) {
        if (dialog) dialog->accept();
        co_return;
    }
    const QString message = AppState::shared().lastWriteError().isEmpty()
        ? QStringLiteral("操作失败")
        : AppState::shared().lastWriteError();
    if (error) {
        error->setText(message);
        error->setVisible(true);
    }
    co_return;
}

Task<void> PlaylistDetailView::removeTrackAsync(Playlist playlist, QString songID,
    QPointer<QDialog> dialog, QPointer<QLabel> error, QPointer<QPushButton> confirm)
{
    auto alive = m_alive;
    if (confirm) confirm->setEnabled(false);
    if (error) error->setVisible(false);
    bool ok = false;
    try {
        ok = co_await AppState::shared().modifyPlaylist(playlist, QStringList{songID}, false);
    } catch (const MusicException&) {
    } catch (const std::exception&) {
    }
    if (!*alive) co_return;
    if (confirm) confirm->setEnabled(true);
    if (ok) {
        QList<Song> songs = m_trackList->songs();
        songs.removeIf([&songID](const Song& song) { return song.id == songID; });
        m_trackList->setSongs(songs);
        renderHeader();
        if (dialog) dialog->accept();
        co_return;
    }
    const QString message = AppState::shared().lastWriteError().isEmpty()
        ? QStringLiteral("操作失败")
        : AppState::shared().lastWriteError();
    if (error) {
        error->setText(message);
        error->setVisible(true);
    }
    co_return;
}

void PlaylistDetailView::showRenameDialog()
{
    if (!m_detail.has_value()) return;
    const Playlist playlist = m_detail->playlist;

    auto* dialog = new QDialog(this);
    dialog->setAttribute(Qt::WA_DeleteOnClose);
    dialog->setWindowTitle(QStringLiteral("重命名歌单"));
    dialog->setModal(true);
    dialog->setFixedWidth(380);
    dialog->setStyleSheet(QStringLiteral("QDialog { background: %1; }").arg(CTColors::panel().name()));

    auto* layout = new QVBoxLayout(dialog);
    layout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl);
    layout->setSpacing(CTSpacing::Lg);
    layout->addWidget(ui::titleLabel(QStringLiteral("重命名歌单"), CTTypography::SectionTitle, true));

    auto* box = new QLineEdit(playlist.name, dialog);
    box->setMaxLength(40);
    box->setPlaceholderText(QStringLiteral("歌单名称"));
    layout->addWidget(box);

    auto* error = ui::secondaryLabel(QString());
    error->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::accent().name()));
    error->setWordWrap(true);
    error->setVisible(false);
    layout->addWidget(error);

    auto* buttons = new QWidget(dialog);
    auto* buttonsLayout = new QHBoxLayout(buttons);
    buttonsLayout->setContentsMargins(0, 0, 0, 0);
    buttonsLayout->setSpacing(CTSpacing::Sm);
    buttonsLayout->addStretch(1);
    auto* cancel = ui::ghostButton(L10n::Common::Cancel);
    auto* confirm = ui::accentButton(QStringLiteral("重命名"));
    buttonsLayout->addWidget(cancel);
    buttonsLayout->addWidget(confirm);
    layout->addWidget(buttons);

    connect(cancel, &QPushButton::clicked, dialog, &QDialog::reject);
    QPointer<QDialog> dialogPtr(dialog);
    QPointer<QLabel> errorPtr(error);
    QPointer<QPushButton> confirmPtr(confirm);
    auto submit = [this, playlist, box, dialogPtr, errorPtr, confirmPtr] {
        const QString name = box->text().trimmed();
        if (name.isEmpty()) return;
        if (confirmPtr && !confirmPtr->isEnabled()) return;
        detach(renameAsync(playlist, name, dialogPtr, errorPtr, confirmPtr));
    };
    connect(confirm, &QPushButton::clicked, this, submit);
    connect(box, &QLineEdit::returnPressed, this, submit);

    dialog->open();
    box->setFocus();
    box->selectAll();
}

void PlaylistDetailView::showDeleteDialog()
{
    if (!m_detail.has_value()) return;
    const Playlist playlist = m_detail->playlist;

    auto* dialog = new QDialog(this);
    dialog->setAttribute(Qt::WA_DeleteOnClose);
    dialog->setWindowTitle(QStringLiteral("删除歌单"));
    dialog->setModal(true);
    dialog->setFixedWidth(360);
    dialog->setStyleSheet(QStringLiteral("QDialog { background: %1; }").arg(CTColors::panel().name()));

    auto* layout = new QVBoxLayout(dialog);
    layout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl);
    layout->setSpacing(CTSpacing::Lg);
    layout->addWidget(ui::titleLabel(QStringLiteral("删除歌单"), CTTypography::SectionTitle, true));
    auto* message = ui::secondaryLabel(
        QStringLiteral("确定要删除「%1」吗？此操作不可撤销。").arg(playlist.name));
    message->setWordWrap(true);
    layout->addWidget(message);

    auto* error = ui::secondaryLabel(QString());
    error->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::accent().name()));
    error->setWordWrap(true);
    error->setVisible(false);
    layout->addWidget(error);

    auto* buttons = new QWidget(dialog);
    auto* buttonsLayout = new QHBoxLayout(buttons);
    buttonsLayout->setContentsMargins(0, 0, 0, 0);
    buttonsLayout->setSpacing(CTSpacing::Sm);
    buttonsLayout->addStretch(1);
    auto* cancel = ui::ghostButton(L10n::Common::Cancel);
    auto* confirm = ui::accentButton(QStringLiteral("删除"));
    buttonsLayout->addWidget(cancel);
    buttonsLayout->addWidget(confirm);
    layout->addWidget(buttons);

    connect(cancel, &QPushButton::clicked, dialog, &QDialog::reject);
    QPointer<QDialog> dialogPtr(dialog);
    QPointer<QLabel> errorPtr(error);
    QPointer<QPushButton> confirmPtr(confirm);
    connect(confirm, &QPushButton::clicked, this,
        [this, playlist, dialogPtr, errorPtr, confirmPtr] {
            detach(deleteAsync(playlist, dialogPtr, errorPtr, confirmPtr));
        });

    dialog->open();
}

void PlaylistDetailView::showRemoveDialog(const Song& song)
{
    if (!m_detail.has_value()) return;
    const Playlist playlist = m_detail->playlist;

    auto* dialog = new QDialog(this);
    dialog->setAttribute(Qt::WA_DeleteOnClose);
    dialog->setWindowTitle(QStringLiteral("从歌单移除"));
    dialog->setModal(true);
    dialog->setFixedWidth(360);
    dialog->setStyleSheet(QStringLiteral("QDialog { background: %1; }").arg(CTColors::panel().name()));

    auto* layout = new QVBoxLayout(dialog);
    layout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl);
    layout->setSpacing(CTSpacing::Lg);
    layout->addWidget(ui::titleLabel(QStringLiteral("从歌单移除"), CTTypography::SectionTitle, true));
    auto* message = ui::secondaryLabel(
        QStringLiteral("确定要从这个歌单移除「%1」吗？").arg(song.title));
    message->setWordWrap(true);
    layout->addWidget(message);

    auto* error = ui::secondaryLabel(QString());
    error->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::accent().name()));
    error->setWordWrap(true);
    error->setVisible(false);
    layout->addWidget(error);

    auto* buttons = new QWidget(dialog);
    auto* buttonsLayout = new QHBoxLayout(buttons);
    buttonsLayout->setContentsMargins(0, 0, 0, 0);
    buttonsLayout->setSpacing(CTSpacing::Sm);
    buttonsLayout->addStretch(1);
    auto* cancel = ui::ghostButton(L10n::Common::Cancel);
    auto* confirm = ui::accentButton(QStringLiteral("移除"));
    buttonsLayout->addWidget(cancel);
    buttonsLayout->addWidget(confirm);
    layout->addWidget(buttons);

    connect(cancel, &QPushButton::clicked, dialog, &QDialog::reject);
    QPointer<QDialog> dialogPtr(dialog);
    QPointer<QLabel> errorPtr(error);
    QPointer<QPushButton> confirmPtr(confirm);
    const QString songID = song.id;
    connect(confirm, &QPushButton::clicked, this,
        [this, playlist, songID, dialogPtr, errorPtr, confirmPtr] {
            detach(removeTrackAsync(playlist, songID, dialogPtr, errorPtr, confirmPtr));
        });

    dialog->open();
}

CT_REGISTER_PAGE(Page::PlaylistDetail, PlaylistDetailView);

} // namespace ct
