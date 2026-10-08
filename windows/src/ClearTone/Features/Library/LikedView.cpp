#include "Features/Library/LikedView.h"

#include "App/AppState.h"
#include "DesignSystem/CTTheme.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Playback/PlayerController.h"

#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QVBoxLayout>

namespace ct {

namespace {

void setHost(QVBoxLayout* layout, QWidget* content, QWidget* persistent = nullptr)
{
    if (content != nullptr && layout->indexOf(content) >= 0 && layout->count() == 1) return;
    while (QLayoutItem* item = layout->takeAt(0)) {
        if (QWidget* widget = item->widget()) {
            if (widget == persistent) {
                widget->hide();
            } else if (widget != content) {
                widget->deleteLater();
            }
        }
        delete item;
    }
    if (content != nullptr) {
        content->show();
        layout->addWidget(content);
    }
}

} // namespace

LikedView::LikedView(QWidget* parent)
    : QWidget(parent)
{
    setObjectName(QStringLiteral("ctLikedView"));
    setStyleSheet(QStringLiteral("QWidget#ctLikedView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    auto* titleStack = new QWidget(this);
    auto* titleLayout = new QVBoxLayout(titleStack);
    titleLayout->setContentsMargins(0, 0, 0, 0);
    titleLayout->setSpacing(CTSpacing::Xs);
    titleLayout->addWidget(ui::titleLabel(QStringLiteral("喜欢的音乐"), CTTypography::PageTitle, true));
    m_subtitle = ui::secondaryLabel(QStringLiteral("把心动的旋律，留在身边。"));
    titleLayout->addWidget(m_subtitle);

    m_playAll = ui::accentButton(QStringLiteral("播放全部"));
    m_playAll->setVisible(false);
    connect(m_playAll, &QPushButton::clicked, this, [] {
        const QList<Song>& songs = AppState::shared().likedSongs();
        if (!songs.isEmpty()) PlayerController::shared().playSongs(songs, 0);
    });

    auto* header = new QWidget(this);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Lg);
    headerLayout->addWidget(titleStack);
    headerLayout->addStretch(1);
    headerLayout->addWidget(m_playAll, 0, Qt::AlignVCenter);
    root->addWidget(header);

    m_host = new QWidget(this);
    m_hostLayout = new QVBoxLayout(m_host);
    m_hostLayout->setContentsMargins(CTSpacing::Xl, 0, CTSpacing::Xl, CTSpacing::Xl);
    m_hostLayout->setSpacing(0);
    root->addWidget(m_host, 1);

    m_list = new SongListView();
    m_list->setEmptyText(QStringLiteral("还没有喜欢的歌曲"));

    const AppState& app = AppState::shared();
    m_lastDataContextKey = app.dataContextKey();
    m_lastLikesVersion = app.likesVersion();
    m_lastLoggedIn = app.isLoggedIn();
    m_appObserver = AppState::shared().changed.subscribe([this] { scheduleAppChange(); });
    m_contextObserver = AppState::shared().dataContextChanged.subscribe([this] { scheduleAppChange(); });
    render();
}

LikedView::~LikedView()
{
    *m_alive = false;
    AppState::shared().changed.unsubscribe(m_appObserver);
    AppState::shared().dataContextChanged.unsubscribe(m_contextObserver);
}

void LikedView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    detach(loadAsync());
}

void LikedView::scheduleAppChange()
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

void LikedView::handleAppChange()
{
    const AppState& app = AppState::shared();
    const QString key = app.dataContextKey();
    const int version = app.likesVersion();
    const bool loggedIn = app.isLoggedIn();
    if (key == m_lastDataContextKey && version == m_lastLikesVersion && loggedIn == m_lastLoggedIn) {
        return;
    }
    const bool contextChanged = key != m_lastDataContextKey;
    m_lastDataContextKey = key;
    m_lastLikesVersion = version;
    m_lastLoggedIn = loggedIn;
    if (contextChanged) {
        detach(loadAsync());
    } else {
        render();
    }
}

Task<void> LikedView::loadAsync()
{
    auto alive = m_alive;
    co_await AppState::shared().loadLikedSongs();
    if (!*alive) co_return;
    render();
    co_return;
}

void LikedView::render()
{
    const AppState& app = AppState::shared();
    const QList<Song>& songs = app.likedSongs();

    if (!app.isLoggedIn()) {
        m_subtitle->setText(QStringLiteral("登录后查看喜欢的歌曲"));
        m_playAll->setVisible(false);
        setHost(m_hostLayout, buildLoginRequired(), m_list);
        return;
    }

    m_subtitle->setText(songs.isEmpty() ? QStringLiteral("把心动的旋律，留在身边。")
                                        : QStringLiteral("%1 首珍藏 · 随时重温").arg(songs.size()));
    m_playAll->setVisible(!songs.isEmpty());

    if (songs.isEmpty()) {
        setHost(m_hostLayout, ui::statusPanel(QStringLiteral("还没有喜欢的歌曲"), false), m_list);
        return;
    }

    m_list->setSongs(songs);
    setHost(m_hostLayout, m_list, m_list);
}

QWidget* LikedView::buildLoginRequired()
{
    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, 60, 0, 60);
    layout->setSpacing(CTSpacing::Md);
    layout->setAlignment(Qt::AlignCenter);

    auto* hint = ui::secondaryLabel(QStringLiteral("登录后查看喜欢的歌曲"));
    hint->setAlignment(Qt::AlignCenter);
    layout->addWidget(hint, 0, Qt::AlignHCenter);

    auto* login = ui::accentButton(QStringLiteral("去登录"));
    connect(login, &QPushButton::clicked, this, [] {
        AppState::shared().setIsLoginPresented(true);
    });
    layout->addWidget(login, 0, Qt::AlignHCenter);
    return panel;
}

CT_REGISTER_PAGE(Page::Liked, LikedView);

} // namespace ct
