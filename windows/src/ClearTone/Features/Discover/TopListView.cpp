#include "Features/Discover/TopListView.h"

#include "App/AppState.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Playback/PlayerController.h"
#include "Providers/Netease/NeteaseProvider.h"
#include "Providers/Netease/NeteaseSocialProvider.h"

#include <QHBoxLayout>
#include <QLabel>
#include <QListWidget>
#include <QPushButton>
#include <QSet>
#include <QSignalBlocker>
#include <QVBoxLayout>

#include <algorithm>
#include <cmath>
#include <utility>

namespace ct {

namespace {

IMusicSocialProvider& socialProvider()
{
    auto* session = AppState::shared().social();
    if (auto* social = dynamic_cast<IMusicSocialProvider*>(session)) return *social;
    return NeteaseSocialProvider::shared();
}

void setHost(QVBoxLayout* layout, QWidget* content, QWidget* persistent = nullptr, bool stretch = false)
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
    if (content == nullptr) return;
    content->show();
    if (stretch) {
        layout->addWidget(content, 1);
    } else {
        layout->addWidget(content);
    }
}

QString unknownUserMessage(const std::exception& error)
{
    return MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
}

QWidget* buildListRow(const TopList& list)
{
    auto* row = new QWidget();
    auto* layout = new QHBoxLayout(row);
    layout->setContentsMargins(CTSpacing::Sm, CTSpacing::Sm, CTSpacing::Sm, CTSpacing::Sm);
    layout->setSpacing(CTSpacing::Sm);

    auto* cover = new CoverImage(row);
    cover->setFixedSize(40, 40);
    cover->setCornerRadius(CTRadius::Small);
    cover->setCoverURL(list.coverURL, 80);
    layout->addWidget(cover);

    auto* text = new QWidget(row);
    auto* textLayout = new QVBoxLayout(text);
    textLayout->setContentsMargins(0, 0, 0, 0);
    textLayout->setSpacing(2);
    auto* name = ui::titleLabel(list.name, CTTypography::Body, true);
    name->setMaximumWidth(150);
    textLayout->addWidget(name);
    if (list.updateFrequency.has_value() && !list.updateFrequency->isEmpty()) {
        textLayout->addWidget(ui::secondaryLabel(*list.updateFrequency));
    }
    layout->addWidget(text, 1);
    return row;
}

QWidget* buildAreaButton(TopSongArea area, bool selected, std::function<void()> action)
{
    auto* button = selected ? ui::accentButton(topSongArea::displayName(area))
                            : ui::ghostButton(topSongArea::displayName(area));
    QObject::connect(button, &QPushButton::clicked, [action = std::move(action)] {
        if (action) action();
    });
    return button;
}

} // namespace

TopListView::TopListView(QWidget* parent)
    : QWidget(parent)
    , m_session(&socialProvider())
{
    setObjectName(QStringLiteral("ctTopListView"));
    setStyleSheet(QStringLiteral("QWidget#ctTopListView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    auto* titleStack = new QWidget(this);
    auto* titleLayout = new QVBoxLayout(titleStack);
    titleLayout->setContentsMargins(0, 0, 0, 0);
    titleLayout->setSpacing(CTSpacing::Xs);
    titleLayout->addWidget(ui::titleLabel(QStringLiteral("排行榜"), CTTypography::PageTitle, true));
    titleLayout->addWidget(ui::secondaryLabel(QStringLiteral("看看大家都在听什么。")));

    auto* header = new QWidget(this);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Md);
    headerLayout->addWidget(titleStack);
    headerLayout->addStretch(1);
    root->addWidget(header);

    m_listHost = new QWidget(this);
    m_listHost->setFixedWidth(240);
    m_listLayout = new QVBoxLayout(m_listHost);
    m_listLayout->setContentsMargins(0, 0, 0, 0);
    m_listLayout->setSpacing(0);

    m_listBox = new QListWidget(this);
    m_listBox->setFrameShape(QFrame::NoFrame);
    m_listBox->setSelectionMode(QAbstractItemView::SingleSelection);
    m_listBox->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
    m_listBox->setStyleSheet(QStringLiteral("QListWidget { background: transparent; border: none; }"
                                            "QListWidget::item { border-radius: 6px; }"
                                            "QListWidget::item:selected { background: %1; }")
                                 .arg(CTColors::overlay().name()));
    connect(m_listBox, &QListWidget::currentRowChanged, this, [this](int row) { selectListRow(row); });

    m_trackTitle = ui::titleLabel(QStringLiteral("选择榜单"), CTTypography::SectionTitle, true);
    m_trackCount = ui::secondaryLabel(QString());
    m_playAll = ui::accentButton(QStringLiteral("播放全部"));
    m_playAll->setEnabled(false);
    connect(m_playAll, &QPushButton::clicked, this, [this] {
        if (!m_tracks.isEmpty()) PlayerController::shared().playSongs(m_tracks, 0);
    });

    auto* trackTitleRow = new QWidget(this);
    auto* trackTitleLayout = new QHBoxLayout(trackTitleRow);
    trackTitleLayout->setContentsMargins(0, 0, 0, 0);
    trackTitleLayout->setSpacing(CTSpacing::Md);
    trackTitleLayout->addWidget(m_trackTitle);
    trackTitleLayout->addWidget(m_trackCount);
    trackTitleLayout->addStretch(1);

    auto* trackHeader = new QWidget(this);
    auto* trackHeaderLayout = new QHBoxLayout(trackHeader);
    trackHeaderLayout->setContentsMargins(CTSpacing::Lg, CTSpacing::Md, CTSpacing::Lg, CTSpacing::Sm);
    trackHeaderLayout->addWidget(trackTitleRow, 1);
    trackHeaderLayout->addWidget(m_playAll, 0, Qt::AlignVCenter);

    m_areaRow = new QWidget(this);
    m_areaLayout = new QHBoxLayout(m_areaRow);
    m_areaLayout->setContentsMargins(CTSpacing::Lg, 0, CTSpacing::Lg, CTSpacing::Sm);
    m_areaLayout->setSpacing(CTSpacing::Sm);
    rebuildAreaChips();

    m_trackHost = new QWidget(this);
    m_trackLayout = new QVBoxLayout(m_trackHost);
    m_trackLayout->setContentsMargins(0, 0, 0, 0);
    m_trackLayout->setSpacing(0);

    auto* trackPane = new QWidget(this);
    auto* trackPaneLayout = new QVBoxLayout(trackPane);
    trackPaneLayout->setContentsMargins(0, 0, 0, 0);
    trackPaneLayout->setSpacing(0);
    trackPaneLayout->addWidget(trackHeader);
    trackPaneLayout->addWidget(m_areaRow);
    trackPaneLayout->addWidget(m_trackHost, 1);

    auto* divider = new QWidget(this);
    divider->setFixedWidth(1);
    divider->setStyleSheet(QStringLiteral("background: %1;").arg(CTColors::overlay().name()));

    auto* columns = new QWidget(this);
    auto* columnsLayout = new QHBoxLayout(columns);
    columnsLayout->setContentsMargins(0, 0, 0, 0);
    columnsLayout->setSpacing(0);
    columnsLayout->addWidget(m_listHost);
    columnsLayout->addWidget(divider);
    columnsLayout->addWidget(trackPane, 1);
    root->addWidget(columns, 1);

    m_songList = new SongListView();
    m_songList->setEmptyText(QStringLiteral("选择左侧榜单查看曲目"));

    m_session.onChanged = [this] { scheduleRenderLists(); };
    renderLists();
    renderTracks();
}

TopListView::~TopListView()
{
    *m_alive = false;
    m_session.onChanged = nullptr;
}

void TopListView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    if (m_loaded) return;
    m_loaded = true;
    detach(m_session.loadAsync());
}

void TopListView::scheduleRenderLists()
{
    if (m_renderListsScheduled) return;
    m_renderListsScheduled = true;
    QMetaObject::invokeMethod(
        this,
        [this] {
            m_renderListsScheduled = false;
            renderLists();
        },
        Qt::QueuedConnection);
}

void TopListView::renderLists()
{
    const QList<TopList>& lists = m_session.lists();
    if (m_session.isLoading() && lists.isEmpty()) {
        setHost(m_listLayout, ui::statusPanel(QStringLiteral("加载中…"), true), m_listBox, true);
        return;
    }
    if (m_session.errorMessage().has_value() && lists.isEmpty()) {
        setHost(m_listLayout,
            ui::errorPanel(*m_session.errorMessage(), [this] { detach(m_session.loadAsync()); }),
            m_listBox, true);
        return;
    }
    if (lists.isEmpty()) {
        setHost(m_listLayout, ui::statusPanel(QStringLiteral("暂无榜单数据"), false), m_listBox, true);
        return;
    }

    QStringList ids;
    for (const TopList& list : lists) ids.append(list.id);
    const QString signature = ids.join(QLatin1Char(','));
    if (signature != m_listsSignature) {
        m_listsSignature = signature;
        const QString selectedID = m_selected.has_value() ? m_selected->id : QString();
        const QSignalBlocker blocker(m_listBox);
        m_listBox->clear();
        for (const TopList& list : lists) {
            auto* item = new QListWidgetItem(m_listBox);
            item->setData(Qt::UserRole, list.id);
            item->setSizeHint(QSize(0, 56));
            m_listBox->setItemWidget(item, buildListRow(list));
        }
        if (!selectedID.isEmpty()) {
            for (int row = 0; row < m_listBox->count(); ++row) {
                if (m_listBox->item(row)->data(Qt::UserRole).toString() == selectedID) {
                    m_listBox->setCurrentRow(row);
                    break;
                }
            }
        }
    }
    setHost(m_listLayout, m_listBox, m_listBox, true);
}

void TopListView::selectListRow(int row)
{
    if (row < 0 || row >= m_session.lists().size()) return;
    detach(loadTracksAsync(m_session.lists()[row]));
}

void TopListView::rebuildAreaChips()
{
    while (QLayoutItem* item = m_areaLayout->takeAt(0)) {
        if (QWidget* widget = item->widget()) widget->deleteLater();
        delete item;
    }
    auto* label = ui::secondaryLabel(QStringLiteral("地区新歌"));
    m_areaLayout->addWidget(label);
    for (TopSongArea area : {TopSongArea::All, TopSongArea::Chinese, TopSongArea::Western,
             TopSongArea::Japan, TopSongArea::Korea}) {
        const bool selected = m_selectedArea.has_value() && *m_selectedArea == area;
        m_areaLayout->addWidget(buildAreaButton(area, selected,
            [this, area] {
                if (m_selectedArea.has_value() && *m_selectedArea == area) return;
                detach(loadAreaAsync(area));
            }));
    }
    m_areaLayout->addStretch(1);
}

Task<void> TopListView::loadTracksAsync(TopList list)
{
    auto alive = m_alive;
    const quint64 token = ++m_trackToken;
    m_selected = list;
    m_selectedArea.reset();
    m_isLoadingTracks = true;
    m_tracksError.reset();
    m_tracks.clear();
    rebuildAreaChips();
    renderTracks();

    try {
        const PlaylistDetail detail = co_await AppState::shared().provider()->fetchPlaylistDetail(
            list.id, CancellationToken::none());
        if (!*alive || token != m_trackToken) co_return;
        QList<Song> collected = detail.tracks;
        if (collected.size() < detail.totalTrackCount) {
            constexpr int pageSize = 100;
            const int pages = std::min(
                4, static_cast<int>(std::ceil(detail.totalTrackCount / static_cast<double>(pageSize))));
            QSet<QString> seen;
            for (const Song& song : std::as_const(collected)) seen.insert(song.id);
            for (int page = 1; page <= pages; ++page) {
                const QList<Song> more = co_await AppState::shared().provider()->fetchPlaylistTracks(
                    list.id, page, pageSize, CancellationToken::none());
                if (!*alive || token != m_trackToken) co_return;
                for (const Song& song : more) {
                    if (seen.contains(song.id)) continue;
                    seen.insert(song.id);
                    collected.append(song);
                }
                if (collected.size() >= detail.totalTrackCount) break;
            }
        }
        m_tracks = collected;
    } catch (const MusicException& error) {
        if (!*alive || token != m_trackToken) co_return;
        m_tracksError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || token != m_trackToken) co_return;
        m_tracksError = unknownUserMessage(error);
    }
    if (!*alive || token != m_trackToken) co_return;
    m_isLoadingTracks = false;
    renderTracks();
    co_return;
}

Task<void> TopListView::loadAreaAsync(TopSongArea area)
{
    auto alive = m_alive;
    const quint64 token = ++m_trackToken;
    m_selected.reset();
    m_selectedArea = area;
    m_isLoadingTracks = true;
    m_tracksError.reset();
    m_tracks.clear();
    rebuildAreaChips();
    renderTracks();

    try {
        const QList<Song> loaded = co_await socialProvider().fetchTopSongs(
            area, CancellationToken::none());
        if (!*alive || token != m_trackToken) co_return;
        m_tracks = loaded;
    } catch (const MusicException& error) {
        if (!*alive || token != m_trackToken) co_return;
        m_tracksError = error.userFacingMessage();
    } catch (const std::exception& error) {
        if (!*alive || token != m_trackToken) co_return;
        m_tracksError = unknownUserMessage(error);
    }
    if (!*alive || token != m_trackToken) co_return;
    m_isLoadingTracks = false;
    renderTracks();
    co_return;
}

void TopListView::renderTracks()
{
    if (m_selected.has_value()) {
        m_trackTitle->setText(m_selected->name);
    } else if (m_selectedArea.has_value()) {
        m_trackTitle->setText(
            QStringLiteral("新歌速递 · %1").arg(topSongArea::displayName(*m_selectedArea)));
    } else {
        m_trackTitle->setText(QStringLiteral("选择榜单"));
    }
    m_trackCount->setText(m_tracks.isEmpty() ? QString() : QStringLiteral("%1 首").arg(m_tracks.size()));
    m_playAll->setEnabled(!m_tracks.isEmpty());

    if (m_isLoadingTracks && m_tracks.isEmpty()) {
        setHost(m_trackLayout, ui::statusPanel(QStringLiteral("加载中…"), true), m_songList, true);
        return;
    }
    if (m_tracksError.has_value() && m_tracks.isEmpty()) {
        setHost(m_trackLayout,
            ui::errorPanel(*m_tracksError, [this] {
                if (m_selected.has_value()) {
                    detach(loadTracksAsync(*m_selected));
                } else if (m_selectedArea.has_value()) {
                    detach(loadAreaAsync(*m_selectedArea));
                }
            }),
            m_songList, true);
        return;
    }
    if (m_tracks.isEmpty()) {
        setHost(m_trackLayout, ui::statusPanel(QStringLiteral("选择左侧榜单查看曲目"), false),
            m_songList, true);
        return;
    }

    m_songList->setSongs(m_tracks);
    setHost(m_trackLayout, m_songList, m_songList, true);
}

CT_REGISTER_PAGE(Page::TopList, TopListView);

} // namespace ct
