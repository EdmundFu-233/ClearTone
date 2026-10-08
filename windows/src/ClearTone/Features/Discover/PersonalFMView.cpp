#include "Features/Discover/PersonalFMView.h"

#include "App/AppState.h"
#include "Core/Logging/CTLog.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Playback/PlayerController.h"
#include "Providers/Netease/NeteaseProvider.h"
#include "Providers/Netease/NeteaseSocialProvider.h"

#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
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
            auto* button = ui::linkButton(artist.name, [id] { AppState::shared().openArtist(id); });
            layout->addWidget(button);
        } else {
            layout->addWidget(ui::secondaryLabel(artist.name));
        }
    }
    return row;
}

QString unknownUserMessage(const std::exception& error)
{
    return MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
}

} // namespace

PersonalFMView::PersonalFMView(QWidget* parent)
    : QWidget(parent)
{
    setObjectName(QStringLiteral("ctPersonalFMView"));
    setStyleSheet(QStringLiteral("QWidget#ctPersonalFMView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    auto* titleStack = new QWidget(this);
    auto* titleLayout = new QVBoxLayout(titleStack);
    titleLayout->setContentsMargins(0, 0, 0, 0);
    titleLayout->setSpacing(CTSpacing::Xs);
    titleLayout->addWidget(ui::titleLabel(QStringLiteral("私人 FM"), CTTypography::PageTitle, true));
    m_subtitle = ui::secondaryLabel(QStringLiteral("根据你的口味生成 endless 流。"));
    titleLayout->addWidget(m_subtitle);

    auto* header = new QWidget(this);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, 0);
    headerLayout->addWidget(titleStack);
    headerLayout->addStretch(1);
    root->addWidget(header);

    m_host = new QWidget(this);
    m_hostLayout = new QVBoxLayout(m_host);
    m_hostLayout->setContentsMargins(0, 0, 0, 0);
    m_hostLayout->setSpacing(0);
    root->addWidget(m_host, 1);

    const AppState& app = AppState::shared();
    m_lastDataContextKey = app.dataContextKey();
    m_lastLikesVersion = app.likesVersion();
    m_lastCanWrite = app.canPerformWrite();
    m_appObserver = AppState::shared().changed.subscribe([this] { scheduleAppChange(); });
    m_contextObserver = AppState::shared().dataContextChanged.subscribe([this] { scheduleAppChange(); });
    m_songObserver = PlayerController::shared().onSongChanged.subscribe([this] { scheduleRender(); });
    m_stateObserver = PlayerController::shared().onStateChanged.subscribe([this] { scheduleRender(); });
    render();
}

PersonalFMView::~PersonalFMView()
{
    *m_alive = false;
    AppState::shared().changed.unsubscribe(m_appObserver);
    AppState::shared().dataContextChanged.unsubscribe(m_contextObserver);
    PlayerController::shared().onSongChanged.unsubscribe(m_songObserver);
    PlayerController::shared().onStateChanged.unsubscribe(m_stateObserver);
}

void PersonalFMView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    if (m_hasLoaded) return;
    m_hasLoaded = true;
    if (AppState::shared().canPerformWrite()) {
        detach(loadAsync());
    } else {
        render();
    }
}

void PersonalFMView::scheduleRender()
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

void PersonalFMView::scheduleAppChange()
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

void PersonalFMView::handleAppChange()
{
    const AppState& app = AppState::shared();
    const QString key = app.dataContextKey();
    const int likesVersion = app.likesVersion();
    const bool canWrite = app.canPerformWrite();
    const bool contextChanged = key != m_lastDataContextKey;
    if (!contextChanged && likesVersion == m_lastLikesVersion && canWrite == m_lastCanWrite) return;
    m_lastDataContextKey = key;
    m_lastLikesVersion = likesVersion;
    m_lastCanWrite = canWrite;
    if (contextChanged) {
        m_loadToken++;
        m_songs.clear();
        m_index = 0;
        m_errorMessage.reset();
        m_isLoading = false;
        m_hasLoaded = true;
        if (canWrite) {
            detach(loadAsync());
        } else {
            render();
        }
        return;
    }
    render();
}

Task<void> PersonalFMView::loadAsync()
{
    auto alive = m_alive;
    const quint64 token = ++m_loadToken;
    m_isLoading = true;
    m_errorMessage.reset();
    render();
    try {
        const QList<Song> batch = co_await socialProvider().fetchPersonalFM(CancellationToken::none());
        if (!*alive || token != m_loadToken) co_return;
        m_songs = batch;
        m_index = 0;
    } catch (const MusicException& error) {
        if (!*alive || token != m_loadToken) co_return;
        if (m_songs.isEmpty()) m_errorMessage = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || token != m_loadToken) co_return;
        if (m_songs.isEmpty()) m_errorMessage = unknownUserMessage(error);
    }
    if (!*alive || token != m_loadToken) co_return;
    m_isLoading = false;
    render();
    co_return;
}

Task<void> PersonalFMView::nextAsync()
{
    auto alive = m_alive;
    if (m_isLoading) co_return;
    m_index++;
    if (m_index < m_songs.size()) {
        render();
        co_return;
    }
    co_await loadAsync();
    if (!*alive) co_return;
    co_return;
}

Task<void> PersonalFMView::toggleLikeAsync(Song song)
{
    auto alive = m_alive;
    if (!AppState::shared().canPerformWrite()) co_return;
    try {
        co_await AppState::shared().toggleLike(song);
    } catch (const MusicException& error) {
        if (!*alive) co_return;
        AppState::shared().publishWriteError(error);
    }
    if (!*alive) co_return;
    render();
    co_return;
}

Task<void> PersonalFMView::dislikeAsync(Song song)
{
    auto alive = m_alive;
    if (!AppState::shared().canPerformWrite()) co_return;
    if (song.source != SongSource::Netease) co_return;
    try {
        co_await socialProvider().dislikeDailyRecommend(song.id, CancellationToken::none());
        if (!*alive) co_return;
        co_await nextAsync();
        co_return;
    } catch (const MusicException& error) {
        if (!*alive) co_return;
        CTLog::general().error(
            QStringLiteral("反馈不喜欢失败: %1").arg(CTLog::sanitize(error.message())));
    } catch (const std::exception& error) {
        if (!*alive) co_return;
        CTLog::general().error(QStringLiteral("反馈不喜欢失败: %1")
                                   .arg(CTLog::sanitize(QString::fromUtf8(error.what()))));
    }
    co_return;
}

void PersonalFMView::render()
{
    const AppState& app = AppState::shared();
    if (!app.canPerformWrite()) {
        m_subtitle->setText(QStringLiteral("登录后使用私人 FM"));
        setHost(m_hostLayout, buildLoginRequired());
        return;
    }
    if (m_isLoading && m_songs.isEmpty()) {
        m_subtitle->setText(QStringLiteral("正在获取推荐…"));
        setHost(m_hostLayout, ui::statusPanel(QStringLiteral("加载中…"), true));
        return;
    }
    if (m_errorMessage.has_value() && m_songs.isEmpty()) {
        m_subtitle->setText(QStringLiteral("根据你的口味生成 endless 流。"));
        setHost(m_hostLayout, ui::errorPanel(*m_errorMessage, [this] { detach(loadAsync()); }));
        return;
    }
    if (m_songs.isEmpty() || m_index < 0 || m_index >= m_songs.size()) {
        m_subtitle->setText(QStringLiteral("根据你的口味生成 endless 流。"));
        setHost(m_hostLayout, ui::statusPanel(QStringLiteral("点「下一首」获取推荐"), false));
        return;
    }
    m_subtitle->setText(QStringLiteral("本批 %1 首 · 第 %2 首").arg(m_songs.size()).arg(m_index + 1));
    setHost(m_hostLayout, buildCurrentPanel(m_songs[m_index]));
}

QWidget* PersonalFMView::buildLoginRequired()
{
    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, 60, 0, 60);
    layout->setSpacing(CTSpacing::Md);
    layout->setAlignment(Qt::AlignCenter);

    auto* title = ui::titleLabel(QStringLiteral("登录后使用私人 FM"), CTTypography::SectionTitle, true);
    title->setAlignment(Qt::AlignCenter);
    layout->addWidget(title, 0, Qt::AlignHCenter);

    auto* hint = ui::secondaryLabel(QStringLiteral("私人 FM 属于账号数据，扫码登录后即可使用。"));
    hint->setAlignment(Qt::AlignCenter);
    layout->addWidget(hint, 0, Qt::AlignHCenter);

    auto* login = ui::accentButton(QStringLiteral("扫码登录"));
    connect(login, &QPushButton::clicked, this, [] {
        AppState::shared().setIsLoginPresented(true);
    });
    layout->addWidget(login, 0, Qt::AlignHCenter);
    return panel;
}

QWidget* PersonalFMView::buildCurrentPanel(const Song& song)
{
    const Song current = song;
    const bool isCurrent = PlayerController::shared().currentSong().has_value()
        && PlayerController::shared().currentSong()->id == current.id;
    const bool isPlaying = isCurrent && PlayerController::shared().playbackState().isPlaying();

    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xxl);
    layout->setSpacing(CTSpacing::Lg);
    layout->setAlignment(Qt::AlignHCenter | Qt::AlignTop);

    auto* cover = new CoverImage(panel);
    cover->setFixedSize(280, 280);
    cover->setCornerRadius(CTRadius::Large);
    cover->setCoverURL(current.coverURL, 560);
    layout->addWidget(cover, 0, Qt::AlignHCenter);

    auto* title = ui::titleLabel(current.title, CTTypography::SectionTitle, true);
    title->setAlignment(Qt::AlignCenter);
    title->setWordWrap(true);
    title->setMaximumWidth(480);
    layout->addWidget(title, 0, Qt::AlignHCenter);

    auto* artists = buildArtistLinks(current.artists);
    layout->addWidget(artists, 0, Qt::AlignHCenter);

    auto* meta = ui::secondaryLabel(QStringLiteral("第 %1 / %2 首 · %3")
                                        .arg(m_index + 1)
                                        .arg(m_songs.size())
                                        .arg(CTFormatting::time(current.duration)));
    meta->setAlignment(Qt::AlignCenter);
    layout->addWidget(meta, 0, Qt::AlignHCenter);

    auto* actions = new QWidget(panel);
    auto* actionsLayout = new QHBoxLayout(actions);
    actionsLayout->setContentsMargins(0, 0, 0, 0);
    actionsLayout->setSpacing(CTSpacing::Md);

    auto* play = ui::accentButton(isPlaying ? QStringLiteral("暂停") : QStringLiteral("播放"));
    connect(play, &QPushButton::clicked, this, [isPlaying, current] {
        if (isPlaying) {
            PlayerController::shared().pause();
        } else if (current.isPlayable) {
            PlayerController::shared().playSong(current);
        }
    });
    actionsLayout->addWidget(play);

    auto* next = ui::ghostButton(QStringLiteral("下一首"));
    connect(next, &QPushButton::clicked, this, [this] { detach(nextAsync()); });
    actionsLayout->addWidget(next);

    const bool liked = AppState::shared().isLiked(current.id);
    auto* like = ui::ghostButton(liked ? QStringLiteral("取消喜欢") : QStringLiteral("喜欢"));
    like->setEnabled(current.source == SongSource::Netease);
    connect(like, &QPushButton::clicked, this, [this, current] { detach(toggleLikeAsync(current)); });
    actionsLayout->addWidget(like);

    auto* dislike = ui::ghostButton(QStringLiteral("不喜欢"));
    dislike->setEnabled(AppState::shared().canPerformWrite()
        && current.source == SongSource::Netease);
    connect(dislike, &QPushButton::clicked, this, [this, current] { detach(dislikeAsync(current)); });
    actionsLayout->addWidget(dislike);

    layout->addWidget(actions, 0, Qt::AlignHCenter);
    layout->addStretch(1);
    return panel;
}

CT_REGISTER_PAGE(Page::PersonalFM, PersonalFMView);

} // namespace ct
