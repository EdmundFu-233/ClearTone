#include "Features/Radio/RadioDetailView.h"

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

#include <QFrame>
#include <QHBoxLayout>
#include <QLabel>
#include <QListWidget>
#include <QPushButton>
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

NeteaseProvider* neteaseProvider()
{
    if (auto* provider = dynamic_cast<NeteaseProvider*>(AppState::shared().provider())) {
        return provider;
    }
    return &NeteaseProvider::shared();
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

QString unknownUserMessage(const std::exception& error)
{
    return MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
}

} // namespace

RadioDetailView::RadioDetailView(QWidget* parent)
    : QWidget(parent)
{
    setObjectName(QStringLiteral("ctRadioDetailView"));
    setStyleSheet(QStringLiteral("QWidget#ctRadioDetailView { background: %1; }")
                      .arg(CTColors::background().name()));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl);
    root->setSpacing(CTSpacing::Lg);

    m_headerHost = new QWidget(this);
    m_headerLayout = new QVBoxLayout(m_headerHost);
    m_headerLayout->setContentsMargins(0, 0, 0, 0);
    m_headerLayout->setSpacing(0);
    root->addWidget(m_headerHost);

    m_statusText = ui::secondaryLabel(QString());
    m_statusText->setVisible(false);
    root->addWidget(m_statusText);

    m_programList = new QListWidget(this);
    m_programList->setFrameShape(QFrame::NoFrame);
    m_programList->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
    m_programList->setStyleSheet(QStringLiteral("QListWidget { background: transparent; border: none; }"
                                                "QListWidget::item { border: none; }"
                                                "QListWidget::item:selected { background: %1; }")
                                     .arg(CTColors::overlay().name()));
    connect(m_programList, &QListWidget::itemDoubleClicked, this, [this](QListWidgetItem* item) {
        if (item == nullptr) return;
        playProgram(item->data(Qt::UserRole).toInt());
    });
    root->addWidget(m_programList, 1);

    m_loadMoreButton = ui::accentButton(QStringLiteral("加载更多节目"));
    m_loadMoreButton->setVisible(false);
    connect(m_loadMoreButton, &QPushButton::clicked, this, [this] {
        const std::optional<QString> id = m_loadedStationID;
        if (id.has_value()) detach(loadProgramsAsync(*id, m_page + 1, m_loadToken));
    });
    root->addWidget(m_loadMoreButton, 0, Qt::AlignHCenter);

    connect(m_programList->verticalScrollBar(), &QScrollBar::valueChanged, this, [this](int value) {
        if (!m_hasMore || m_isLoadingMore || m_loading) return;
        QScrollBar* bar = m_programList->verticalScrollBar();
        if (value >= bar->maximum() - 24) {
            const std::optional<QString> id = m_loadedStationID;
            if (id.has_value()) detach(loadProgramsAsync(*id, m_page + 1, m_loadToken));
        }
    });

    m_lastSelectedID = AppState::shared().selectedRadioID().value_or(QString());
    m_appObserver = AppState::shared().changed.subscribe([this] { scheduleAppChange(); });
    load();
}

RadioDetailView::~RadioDetailView()
{
    *m_alive = false;
    AppState::shared().changed.unsubscribe(m_appObserver);
}

void RadioDetailView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    m_isAttached = true;
    load();
}

void RadioDetailView::hideEvent(QHideEvent* event)
{
    QWidget::hideEvent(event);
    m_isAttached = false;
}

void RadioDetailView::scheduleAppChange()
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

void RadioDetailView::handleAppChange()
{
    if (!*m_alive) return;
    const QString selected = AppState::shared().selectedRadioID().value_or(QString());
    if (selected != m_lastSelectedID) {
        m_lastSelectedID = selected;
        if (m_isAttached) load();
    }
}

void RadioDetailView::load()
{
    const std::optional<QString> id = AppState::shared().selectedRadioID();
    if (!id.has_value() || id->isEmpty()) {
        updateStatus(QStringLiteral("未选择电台"), true);
        return;
    }
    if (m_loadedStationID == id) return;
    m_loadedStationID = id;
    m_page = 1;
    m_programCount = 0;
    m_station.reset();
    m_programs.clear();
    m_isLoadingMore = false;
    m_hasMore = false;
    renderHeader();
    renderPrograms();
    const quint64 token = ++m_loadToken;
    detach(loadStationAsync(*id, token));
}

Task<void> RadioDetailView::loadStationAsync(QString id, quint64 token)
{
    auto alive = m_alive;
    updateStatus(L10n::Common::Loading, true);
    try {
        RadioStation station
            = co_await socialProvider().fetchRadioStationDetail(id, CancellationToken::none());
        if (!*alive || token != m_loadToken) co_return;
        if (AppState::shared().selectedRadioID().value_or(QString()) != id) co_return;
        m_station = station;
        m_programCount = station.programCount;
        renderHeader();
        co_await loadProgramsAsync(id, 1, token);
    } catch (const MusicException& error) {
        if (!*alive || token != m_loadToken) co_return;
        if (AppState::shared().selectedRadioID().value_or(QString()) != id) co_return;
        updateStatus(error.userFacingMessage(), true);
    } catch (const std::exception& error) {
        if (!*alive || token != m_loadToken) co_return;
        updateStatus(unknownUserMessage(error), true);
    }
}

Task<void> RadioDetailView::loadProgramsAsync(QString id, int page, quint64 token)
{
    auto alive = m_alive;
    if (m_loading) co_return;
    m_loading = true;
    if (page > 1) {
        m_isLoadingMore = true;
        renderPrograms();
    }
    try {
        QList<RadioProgram> programs
            = co_await neteaseProvider()->fetchRadioPrograms(id, page, 30, CancellationToken::none());
        if (!*alive || token != m_loadToken) co_return;
        if (AppState::shared().selectedRadioID().value_or(QString()) != id) co_return;
        for (const RadioProgram& program : programs) m_programs.append(program);
        m_page = page;
        const bool hasMore = m_programCount > 0 ? m_page * 30 < m_programCount
                                                : programs.size() >= 30;
        m_hasMore = hasMore;
        m_loadMoreButton->setVisible(hasMore);
        m_isLoadingMore = false;
        renderPrograms();
        updateStatus(m_programs.isEmpty() ? QStringLiteral("暂无节目") : QString(), m_programs.isEmpty());
    } catch (const MusicException& error) {
        m_isLoadingMore = false;
        m_loading = false;
        if (!*alive || token != m_loadToken) co_return;
        if (AppState::shared().selectedRadioID().value_or(QString()) != id) co_return;
        updateStatus(error.userFacingMessage(), true);
        co_return;
    } catch (const std::exception& error) {
        m_isLoadingMore = false;
        m_loading = false;
        if (!*alive || token != m_loadToken) co_return;
        updateStatus(unknownUserMessage(error), true);
        co_return;
    }
    m_loading = false;
    co_return;
}

void RadioDetailView::updateStatus(const QString& text, bool visible)
{
    m_statusText->setText(text);
    m_statusText->setVisible(visible);
}

QString RadioDetailView::metaText(const RadioStation& station) const
{
    QStringList parts;
    if (station.creatorName.has_value() && !station.creatorName->isEmpty()) {
        parts.append(*station.creatorName);
    }
    if (station.programCount > 0) parts.append(QStringLiteral("%1 期节目").arg(station.programCount));
    if (station.subscriberCount > 0) {
        parts.append(QStringLiteral("%1 人订阅").arg(CTFormatting::count(station.subscriberCount)));
    }
    return parts.join(QStringLiteral(" · "));
}

void RadioDetailView::renderHeader()
{
    clearLayout(m_headerLayout);
    if (!m_station.has_value()) return;
    const RadioStation station = *m_station;

    auto* row = new QWidget();
    auto* layout = new QHBoxLayout(row);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Lg);

    auto* cover = new CoverImage(row);
    cover->setFixedSize(130, 130);
    cover->setCornerRadius(CTRadius::Medium);
    cover->setCoverURL(station.coverURL, 260);
    layout->addWidget(cover, 0, Qt::AlignTop);

    auto* info = new QWidget(row);
    auto* infoLayout = new QVBoxLayout(info);
    infoLayout->setContentsMargins(0, 0, 0, 0);
    infoLayout->setSpacing(CTSpacing::Sm);

    auto* name = ui::titleElidedLabel(station.name, 24, true);
    name->setMaximumWidth(520);
    infoLayout->addWidget(name);

    infoLayout->addWidget(ui::secondaryLabel(metaText(station)));

    if (station.descriptionText.has_value() && !station.descriptionText->isEmpty()) {
        auto* description = ui::secondaryElidedLabel(*station.descriptionText);
        description->setMaximumWidth(520);
        infoLayout->addWidget(description);
    }

    auto* actions = new QWidget(info);
    auto* actionsLayout = new QHBoxLayout(actions);
    actionsLayout->setContentsMargins(0, 0, 0, 0);
    actionsLayout->setSpacing(CTSpacing::Sm);

    auto* subscribe = ui::accentButton(station.isSubscribed ? QStringLiteral("取消订阅")
                                                            : QStringLiteral("订阅电台"));
    subscribe->setEnabled(AppState::shared().isLoggedIn());
    connect(subscribe, &QPushButton::clicked, this,
        [this] { detach(toggleSubscribeAsync(m_loadToken)); });
    actionsLayout->addWidget(subscribe);

    auto* playAll = ui::ghostButton(QStringLiteral("播放全部"));
    playAll->setEnabled(!playableSongs().isEmpty());
    connect(playAll, &QPushButton::clicked, this, [this] {
        const QList<Song> songs = playableSongs();
        if (!songs.isEmpty()) PlayerController::shared().playSongs(songs, 0);
    });
    actionsLayout->addWidget(playAll);
    actionsLayout->addStretch(1);
    infoLayout->addWidget(actions);
    infoLayout->addStretch(1);

    layout->addWidget(info, 1);
    m_headerLayout->addWidget(row);
}

Task<void> RadioDetailView::toggleSubscribeAsync(quint64 token)
{
    auto alive = m_alive;
    if (!m_station.has_value()) co_return;
    const RadioStation station = *m_station;
    try {
        co_await socialProvider().subscribeRadio(station.id, !station.isSubscribed,
            CancellationToken::none());
        RadioStation refreshed
            = co_await socialProvider().fetchRadioStationDetail(station.id, CancellationToken::none());
        if (!*alive || token != m_loadToken) co_return;
        if (AppState::shared().selectedRadioID().value_or(QString()) != station.id) co_return;
        m_station = refreshed;
        m_programCount = refreshed.programCount;
        renderHeader();
    } catch (const MusicException& error) {
        if (!*alive) co_return;
        AppState::shared().publishWriteError(error);
        updateStatus(error.userFacingMessage(), true);
    } catch (const std::exception& error) {
        if (!*alive) co_return;
        updateStatus(unknownUserMessage(error), true);
    }
}

QList<Song> RadioDetailView::playableSongs() const
{
    QList<Song> songs;
    for (const RadioProgram& program : m_programs) {
        if (program.song.has_value() && program.isPlayable()) songs.append(*program.song);
    }
    return songs;
}

QList<int> RadioDetailView::playableIndexMap() const
{
    QList<int> map;
    int songIndex = -1;
    for (const RadioProgram& program : m_programs) {
        if (program.song.has_value() && program.isPlayable()) ++songIndex;
        map.append(songIndex);
    }
    return map;
}

void RadioDetailView::playProgram(int programIndex)
{
    if (programIndex < 0 || programIndex >= m_programs.size()) return;
    const QList<int> map = playableIndexMap();
    if (programIndex >= map.size() || map.at(programIndex) < 0) return;
    PlayerController::shared().playSongs(playableSongs(), map.at(programIndex));
}

QListWidgetItem* RadioDetailView::buildProgramRow(
    const RadioProgram& program, int programIndex, int songIndex)
{
    auto* item = new QListWidgetItem(m_programList);
    item->setSizeHint(QSize(0, 68));
    item->setData(Qt::UserRole, programIndex);

    auto* widget = new QWidget(m_programList);
    auto* layout = new QHBoxLayout(widget);
    layout->setContentsMargins(CTSpacing::Sm, CTSpacing::Sm, CTSpacing::Sm, CTSpacing::Sm);
    layout->setSpacing(CTSpacing::Md);

    auto* cover = new CoverImage(widget);
    cover->setFixedSize(44, 44);
    cover->setCornerRadius(CTRadius::Small);
    cover->setCoverURL(program.coverURL, 88);
    layout->addWidget(cover, 0, Qt::AlignVCenter);

    auto* text = new QWidget(widget);
    auto* textLayout = new QVBoxLayout(text);
    textLayout->setContentsMargins(0, 0, 0, 0);
    textLayout->setSpacing(2);
    auto* title = ui::titleLabel(program.title, CTTypography::Body, true);
    title->setStyleSheet(QStringLiteral("color: %1;").arg(
        songIndex >= 0 ? CTColors::textPrimary().name() : CTColors::textSecondary().name()));
    textLayout->addWidget(title);

    auto* meta = new QWidget(text);
    auto* metaLayout = new QHBoxLayout(meta);
    metaLayout->setContentsMargins(0, 0, 0, 0);
    metaLayout->setSpacing(CTSpacing::Sm);
    if (program.duration > 0) {
        metaLayout->addWidget(ui::secondaryLabel(CTFormatting::time(program.duration)));
    }
    if (program.createTime.has_value() && program.createTime->isValid()) {
        metaLayout->addWidget(ui::secondaryLabel(
            program.createTime->toLocalTime().toString(QStringLiteral("yyyy-MM-dd"))));
    }
    if (program.playCount > 0) {
        metaLayout->addWidget(ui::secondaryLabel(
            QStringLiteral("%1 次播放").arg(CTFormatting::count(program.playCount))));
    }
    metaLayout->addStretch(1);
    textLayout->addWidget(meta);
    layout->addWidget(text, 1);

    auto* play = new QPushButton(QStringLiteral("\uE13F"), widget);
    play->setFlat(true);
    play->setCursor(Qt::PointingHandCursor);
    play->setFixedSize(32, 32);
    play->setEnabled(songIndex >= 0);
    play->setStyleSheet(QStringLiteral(
        "QPushButton { background: transparent; border: none; color: %1; font-size: 16px;"
        " font-family: 'lucide'; }"
        "QPushButton:hover { background: %2; border-radius: 6px; }")
                            .arg(CTColors::accent().name(), CTColors::overlay().name()));
    connect(play, &QPushButton::clicked, this, [this, programIndex] { playProgram(programIndex); });
    layout->addWidget(play, 0, Qt::AlignVCenter);

    m_programList->setItemWidget(item, widget);
    return item;
}

void RadioDetailView::renderPrograms()
{
    const QScrollBar* bar = m_programList->verticalScrollBar();
    const int scrollValue = bar->value();
    m_programList->clear();
    const QList<int> map = playableIndexMap();
    for (int index = 0; index < m_programs.size(); ++index) {
        buildProgramRow(m_programs.at(index), index, index < map.size() ? map.at(index) : -1);
    }
    m_programList->verticalScrollBar()->setValue(
        qMin(scrollValue, m_programList->verticalScrollBar()->maximum()));
    m_loadMoreButton->setVisible(m_hasMore);
}

CT_REGISTER_PAGE(Page::RadioDetail, RadioDetailView);

} // namespace ct
