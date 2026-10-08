#include "Features/Library/RecentView.h"

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

RecentView::RecentView(QWidget* parent)
    : QWidget(parent)
{
    setObjectName(QStringLiteral("ctRecentView"));
    setStyleSheet(QStringLiteral("QWidget#ctRecentView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    auto* titleStack = new QWidget(this);
    auto* titleLayout = new QVBoxLayout(titleStack);
    titleLayout->setContentsMargins(0, 0, 0, 0);
    titleLayout->setSpacing(CTSpacing::Xs);
    titleLayout->addWidget(ui::titleLabel(QStringLiteral("最近播放"), CTTypography::PageTitle, true));
    m_subtitle = ui::secondaryLabel(QStringLiteral("听过的歌会出现在这里。"));
    titleLayout->addWidget(m_subtitle);

    m_playAll = ui::accentButton(QStringLiteral("播放全部"));
    m_playAll->setVisible(false);
    connect(m_playAll, &QPushButton::clicked, this, [] {
        const QList<Song>& songs = PlayerController::shared().recentlyPlayed();
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
    m_list->setEmptyText(QStringLiteral("暂无播放记录"));

    m_songObserver = PlayerController::shared().onSongChanged.subscribe([this] { scheduleRender(); });
    m_recentObserver
        = PlayerController::shared().onRecentlyPlayedChanged.subscribe([this] { scheduleRender(); });
    render();
}

RecentView::~RecentView()
{
    PlayerController::shared().onSongChanged.unsubscribe(m_songObserver);
    PlayerController::shared().onRecentlyPlayedChanged.unsubscribe(m_recentObserver);
}

void RecentView::scheduleRender()
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

void RecentView::render()
{
    const QList<Song> songs = PlayerController::shared().recentlyPlayed();
    m_playAll->setVisible(!songs.isEmpty());
    m_subtitle->setText(songs.isEmpty() ? QStringLiteral("听过的歌会出现在这里。")
                                        : QStringLiteral("最近 %1 首").arg(songs.size()));

    if (songs.isEmpty()) {
        setHost(m_hostLayout, ui::statusPanel(QStringLiteral("暂无播放记录"), false), m_list);
        return;
    }

    m_list->setSongs(songs);
    setHost(m_hostLayout, m_list, m_list);
}

CT_REGISTER_PAGE(Page::Recent, RecentView);

} // namespace ct
