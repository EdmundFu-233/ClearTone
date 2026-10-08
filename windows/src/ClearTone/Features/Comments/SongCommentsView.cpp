#include "Features/Comments/SongCommentsView.h"

#include "App/AppState.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Playback/PlayerController.h"
#include "Providers/Netease/NeteaseProvider.h"
#include "Providers/Netease/NeteaseSocialProvider.h"

#include <QFrame>
#include <QHBoxLayout>
#include <QLabel>
#include <QProgressBar>
#include <QPushButton>
#include <QScrollArea>
#include <QScrollBar>
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

QString relativeTime(const QDateTime& date)
{
    if (!date.isValid()) return QString();
    const double seconds = date.msecsTo(QDateTime::currentDateTime()) / 1000.0;
    if (seconds < 60) return QStringLiteral("刚刚");
    if (seconds < 3600) return QStringLiteral("%1 分钟前").arg(static_cast<int>(seconds / 60));
    if (seconds < 86400) return QStringLiteral("%1 小时前").arg(static_cast<int>(seconds / 3600));
    if (seconds < 172800) return QStringLiteral("昨天");
    if (seconds < 604800) return QStringLiteral("%1 天前").arg(static_cast<int>(seconds / 86400));
    return date.toLocalTime().toString(QStringLiteral("yyyy-MM-dd"));
}

} // namespace

SongCommentsView::SongCommentsView(QWidget* parent)
    : QWidget(parent)
    , m_store(&socialProvider())
{
    setObjectName(QStringLiteral("ctSongCommentsView"));
    setStyleSheet(QStringLiteral("QWidget#ctSongCommentsView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    m_headerHost = new QWidget(this);
    m_headerLayout = new QVBoxLayout(m_headerHost);
    m_headerLayout->setContentsMargins(0, 0, 0, 0);
    m_headerLayout->setSpacing(0);
    root->addWidget(m_headerHost);

    m_content = new QWidget();
    m_contentLayout = new QVBoxLayout(m_content);
    m_contentLayout->setContentsMargins(0, 0, 0, 0);
    m_contentLayout->setSpacing(0);
    m_scroll = ui::scrollWrapper(m_content);
    root->addWidget(m_scroll, 1);

    connect(m_scroll->verticalScrollBar(), &QScrollBar::valueChanged, this, [this](int value) {
        if (m_rendering) return;
        if (!m_store.hasMore() || m_store.isLoadingMore() || m_store.isLoading()) return;
        if (value >= m_scroll->verticalScrollBar()->maximum() - 24) loadMore();
    });

    m_store.onChanged = [this, alive = m_alive] {
        if (!*alive) return;
        scheduleRender();
    };

    m_lastDataContextKey = AppState::shared().dataContextKey();
    m_appObserver = AppState::shared().changed.subscribe([this] { scheduleAppChange(); });
    m_contextObserver = AppState::shared().dataContextChanged.subscribe([this] { scheduleAppChange(); });
    render();
}

SongCommentsView::~SongCommentsView()
{
    *m_alive = false;
    AppState::shared().changed.unsubscribe(m_appObserver);
    AppState::shared().dataContextChanged.unsubscribe(m_contextObserver);
}

void SongCommentsView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    m_isAttached = true;
    loadComments();
}

void SongCommentsView::hideEvent(QHideEvent* event)
{
    QWidget::hideEvent(event);
    m_isAttached = false;
}

void SongCommentsView::scheduleRender()
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

void SongCommentsView::scheduleAppChange()
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

void SongCommentsView::handleAppChange()
{
    const QString key = AppState::shared().dataContextKey();
    const bool contextChanged = key != m_lastDataContextKey;
    if (contextChanged) m_lastDataContextKey = key;

    const std::optional<Song> song = AppState::shared().commentSong();
    const QString currentID = song.has_value() ? song->id : QString();
    const QString loadedID = m_song.has_value() ? m_song->id : QString();
    const bool songChanged = currentID != loadedID;

    if ((contextChanged || songChanged) && m_isAttached) loadComments();
}

void SongCommentsView::loadComments()
{
    const std::optional<Song> song = AppState::shared().commentSong();
    if (!song.has_value()) {
        m_song.reset();
        m_loadToken++;
        render();
        return;
    }
    const quint64 token = ++m_loadToken;
    m_song = song;
    render();
    detach(loadCommentsAsync(*song, m_store.sort(), token));
}

void SongCommentsView::changeSort(CommentSort sort)
{
    if (!m_song.has_value() || m_store.sort() == sort) return;
    const quint64 token = ++m_loadToken;
    detach(changeSortAsync(sort, token));
}

void SongCommentsView::loadMore()
{
    detach(loadMoreAsync());
}

void SongCommentsView::toggleLike(const Comment& comment)
{
    if (!AppState::shared().canPerformWrite()) return;
    detach(toggleLikeAsync(comment));
}

Task<void> SongCommentsView::loadCommentsAsync(Song song, CommentSort sort, quint64 token)
{
    auto alive = m_alive;
    try {
        co_await m_store.loadAsync(song, sort, CancellationToken::none());
    } catch (const MusicException&) {
    } catch (const std::exception&) {
    }
    if (!*alive || m_loadToken != token) co_return;
    if (m_store.song().has_value()) m_song = *m_store.song();
    render();
    m_scroll->verticalScrollBar()->setValue(0);
    co_return;
}

Task<void> SongCommentsView::changeSortAsync(CommentSort sort, quint64 token)
{
    auto alive = m_alive;
    if (!m_song.has_value()) co_return;
    const Song song = *m_song;
    try {
        co_await m_store.loadAsync(song, sort, CancellationToken::none());
    } catch (const MusicException&) {
    } catch (const std::exception&) {
    }
    if (!*alive || m_loadToken != token) co_return;
    if (m_store.song().has_value()) m_song = *m_store.song();
    render();
    m_scroll->verticalScrollBar()->setValue(0);
    co_return;
}

Task<void> SongCommentsView::loadMoreAsync()
{
    auto alive = m_alive;
    try {
        co_await m_store.loadMoreAsync(CancellationToken::none());
    } catch (const MusicException&) {
    } catch (const std::exception&) {
    }
    if (!*alive) co_return;
    render();
    co_return;
}

Task<void> SongCommentsView::toggleLikeAsync(Comment comment)
{
    auto alive = m_alive;
    try {
        co_await m_store.toggleLikeAsync(comment, CancellationToken::none());
    } catch (const MusicException&) {
    } catch (const std::exception&) {
    }
    if (!*alive) co_return;
    render();
    co_return;
}

void SongCommentsView::render()
{
    if (!*m_alive) return;
    m_rendering = true;
    const int scrollValue = m_scroll->verticalScrollBar()->value();

    clearLayout(m_headerLayout);
    if (m_song.has_value()) m_headerLayout->addWidget(buildHeader());

    clearLayout(m_contentLayout);
    const bool hasSong = m_song.has_value();
    const bool hasError = m_store.errorMessage().has_value();
    const bool hasComments = !m_store.comments().isEmpty();
    if (!hasSong) {
        m_contentLayout->addWidget(ui::statusPanel(QStringLiteral("暂无内容"), false));
    } else if (m_store.isLoading()) {
        m_contentLayout->addWidget(ui::statusPanel(QStringLiteral("加载中…"), true));
    } else if (hasError) {
        m_contentLayout->addWidget(ui::errorPanel(*m_store.errorMessage(), [this] { loadComments(); }));
    } else if (!hasComments) {
        m_contentLayout->addWidget(ui::statusPanel(QStringLiteral("暂无内容"), false));
    } else {
        for (const Comment& comment : m_store.comments()) {
            m_contentLayout->addWidget(buildRow(comment));
        }
        m_contentLayout->addWidget(buildFooter());
    }
    m_contentLayout->addStretch(1);

    m_scroll->verticalScrollBar()->setValue(
        qMin(scrollValue, m_scroll->verticalScrollBar()->maximum()));
    m_rendering = false;
}

QWidget* SongCommentsView::buildHeader()
{
    const Song song = *m_song;

    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Md);
    layout->setSpacing(CTSpacing::Md);

    auto* top = new QWidget(panel);
    auto* topLayout = new QHBoxLayout(top);
    topLayout->setContentsMargins(0, 0, 0, 0);
    topLayout->setSpacing(CTSpacing::Lg);

    auto* cover = new CoverImage(top);
    cover->setFixedSize(72, 72);
    cover->setCornerRadius(CTRadius::Small);
    cover->setCoverURL(song.coverURL, 144);
    topLayout->addWidget(cover, 0, Qt::AlignTop);

    auto* info = new QWidget(top);
    auto* infoLayout = new QVBoxLayout(info);
    infoLayout->setContentsMargins(0, 0, 0, 0);
    infoLayout->setSpacing(4);
    auto* title = ui::titleLabel(song.title, CTTypography::PageTitle, true);
    title->setWordWrap(true);
    infoLayout->addWidget(title);
    const QString subtitle = (!song.album.has_value() || song.album->name.isEmpty())
        ? song.artistNames()
        : QStringLiteral("%1 · %2").arg(song.artistNames(), song.album->name);
    infoLayout->addWidget(ui::secondaryLabel(subtitle));
    topLayout->addWidget(info, 1);

    auto* play = ui::ghostButton(QStringLiteral("播放"));
    connect(play, &QPushButton::clicked, this, [song] {
        PlayerController::shared().playSongs(QList<Song>{song}, 0);
    });
    topLayout->addWidget(play, 0, Qt::AlignVCenter);
    layout->addWidget(top);

    auto* sortRow = new QWidget(panel);
    auto* sortLayout = new QHBoxLayout(sortRow);
    sortLayout->setContentsMargins(0, 0, 0, 0);
    sortLayout->setSpacing(CTSpacing::Sm);
    for (const CommentSort sort : {CommentSort::Recommended, CommentSort::Hot, CommentSort::Newest}) {
        QPushButton* button = nullptr;
        if (m_store.sort() == sort) {
            button = ui::accentButton(commentSort::displayName(sort));
        } else {
            button = ui::ghostButton(commentSort::displayName(sort));
        }
        connect(button, &QPushButton::clicked, this, [this, sort] { changeSort(sort); });
        sortLayout->addWidget(button);
    }
    sortLayout->addStretch(1);
    sortLayout->addWidget(
        ui::secondaryLabel(QStringLiteral("%1 条评论").arg(m_store.total())), 0, Qt::AlignVCenter);
    layout->addWidget(sortRow);

    auto* note = ui::secondaryLabel(AppState::shared().canPerformWrite()
            ? QStringLiteral("发表评论依赖网易云的反作弊校验，当前版本仅支持阅读与点赞")
            : QStringLiteral("登录后可发表评论、点赞"));
    note->setWordWrap(true);
    layout->addWidget(note);

    layout->addWidget(ui::separator());
    return panel;
}

QWidget* SongCommentsView::buildRow(const Comment& comment)
{
    auto* row = new QWidget();
    auto* layout = new QHBoxLayout(row);
    layout->setContentsMargins(CTSpacing::Lg, CTSpacing::Md, CTSpacing::Lg, CTSpacing::Md);
    layout->setSpacing(CTSpacing::Md);

    auto* avatar = new CoverImage(row);
    avatar->setFixedSize(36, 36);
    avatar->setCornerRadius(18);
    avatar->setCoverURL(comment.avatarURL, 72);
    layout->addWidget(avatar, 0, Qt::AlignTop);

    auto* right = new QWidget(row);
    auto* rightLayout = new QVBoxLayout(right);
    rightLayout->setContentsMargins(0, 0, 0, 0);
    rightLayout->setSpacing(CTSpacing::Xs);

    auto* nameRow = new QWidget(right);
    auto* nameLayout = new QHBoxLayout(nameRow);
    nameLayout->setContentsMargins(0, 0, 0, 0);
    nameLayout->setSpacing(CTSpacing::Sm);
    nameLayout->addWidget(ui::titleLabel(comment.nickname, CTTypography::Body, true));
    if (comment.isMine) {
        auto* mine = new QLabel(QStringLiteral("我"), nameRow);
        mine->setStyleSheet(QStringLiteral("background: %1; color: %2; border-radius: 8px; "
                                           "padding: 1px 5px; font-size: 12px;")
                                .arg(CTColors::overlay().name(), CTColors::accent().name()));
        nameLayout->addWidget(mine);
    }
    nameLayout->addWidget(ui::secondaryLabel(relativeTime(comment.time)));
    nameLayout->addStretch(1);
    rightLayout->addWidget(nameRow);

    if (comment.replyToNickname.has_value()) {
        auto* quote = new QFrame(right);
        quote->setObjectName(QStringLiteral("ctQuote"));
        quote->setStyleSheet(QStringLiteral("QFrame#ctQuote { background: %1; border-radius: %2px; }")
                                 .arg(CTColors::overlay().name())
                                 .arg(CTRadius::Small));
        auto* quoteLayout = new QVBoxLayout(quote);
        quoteLayout->setContentsMargins(CTSpacing::Xs, CTSpacing::Xs, CTSpacing::Xs, CTSpacing::Xs);
        auto* text = ui::secondaryLabel(QStringLiteral("回复 @%1：%2")
                                            .arg(comment.replyToNickname.value_or(QString()),
                                                comment.replyToContent.value_or(QString())));
        text->setWordWrap(true);
        quoteLayout->addWidget(text);
        rightLayout->addWidget(quote);
    }

    auto* content = new QLabel(comment.content);
    content->setWordWrap(true);
    content->setMaximumWidth(720);
    content->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::textPrimary().name()));
    rightLayout->addWidget(content);

    auto* actions = new QWidget(right);
    auto* actionsLayout = new QHBoxLayout(actions);
    actionsLayout->setContentsMargins(0, 0, 0, 0);
    actionsLayout->setSpacing(CTSpacing::Lg);

    const bool pending = m_store.pendingLikeIDs().contains(comment.id);
    const QColor likeColor = comment.isLiked ? CTColors::accent() : CTColors::textSecondary();
    const QString likeText = comment.likedCount > 0
        ? QStringLiteral("♥ %1").arg(comment.likedCount)
        : QStringLiteral("♥");
    auto* like = new QPushButton(likeText, actions);
    like->setFlat(true);
    like->setCursor(Qt::PointingHandCursor);
    like->setEnabled(AppState::shared().canPerformWrite() && !pending);
    like->setStyleSheet(QStringLiteral("QPushButton { color: %1; border: none; background: transparent; "
                                       "padding: 2px 4px; font-size: 12px; }")
                            .arg(likeColor.name()));
    connect(like, &QPushButton::clicked, this, [this, comment] { toggleLike(comment); });
    actionsLayout->addWidget(like);

    if (comment.replyCount > 0) {
        actionsLayout->addWidget(
            ui::secondaryLabel(QStringLiteral("%1 条回复").arg(comment.replyCount)), 0, Qt::AlignVCenter);
    }
    actionsLayout->addStretch(1);
    rightLayout->addWidget(actions);

    layout->addWidget(right, 1);
    return row;
}

QWidget* SongCommentsView::buildFooter()
{
    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, CTSpacing::Md, 0, CTSpacing::Lg);
    layout->setSpacing(CTSpacing::Sm);
    layout->setAlignment(Qt::AlignHCenter);

    if (m_store.likeError().has_value()) {
        auto* error = ui::secondaryLabel(*m_store.likeError());
        error->setAlignment(Qt::AlignCenter);
        layout->addWidget(error, 0, Qt::AlignHCenter);
    }

    if (m_store.isLoadingMore()) {
        auto* progress = new QProgressBar(panel);
        progress->setRange(0, 0);
        progress->setTextVisible(false);
        progress->setFixedWidth(160);
        progress->setFixedHeight(4);
        layout->addWidget(progress, 0, Qt::AlignHCenter);
    } else if (m_store.paginationError().has_value() && m_store.hasMore()) {
        auto* error = ui::secondaryLabel(*m_store.paginationError());
        error->setAlignment(Qt::AlignCenter);
        layout->addWidget(error, 0, Qt::AlignHCenter);
        layout->addWidget(ui::linkButton(QStringLiteral("重试加载更多"), [this] { loadMore(); }),
            0, Qt::AlignHCenter);
    } else if (m_store.hasMore()) {
        auto* more = ui::ghostButton(QStringLiteral("加载更多"));
        connect(more, &QPushButton::clicked, this, [this] { loadMore(); });
        layout->addWidget(more, 0, Qt::AlignHCenter);
    }
    return panel;
}

CT_REGISTER_PAGE(Page::SongComments, SongCommentsView);

} // namespace ct
