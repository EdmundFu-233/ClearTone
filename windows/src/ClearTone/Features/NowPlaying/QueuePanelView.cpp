#include "Features/NowPlaying/QueuePanelView.h"

#include "App/AppState.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "DesignSystem/L10n.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Playback/PlayerController.h"

#include <QFrame>
#include <QHBoxLayout>
#include <QLabel>
#include <QListWidget>
#include <QMenu>
#include <QMetaObject>
#include <QPushButton>
#include <QVBoxLayout>

namespace ct {

namespace {

QPushButton* makeGlyphButton(const QString& glyph, const QString& tip, QWidget* parent, double size)
{
    auto* button = new QPushButton(glyph, parent);
    button->setFlat(true);
    button->setCursor(Qt::PointingHandCursor);
    button->setToolTip(tip);
    button->setFixedSize(28, 28);
    button->setStyleSheet(QStringLiteral(
        "QPushButton { background: transparent; border: none; color: %1; font-size: %2px;"
        " font-family: 'Segoe MDL2 Assets', 'Segoe Fluent Icons'; }"
        "QPushButton:hover { background: %3; border-radius: 6px; }")
                              .arg(CTColors::textPrimary().name())
                              .arg(size)
                              .arg(CTColors::overlay().name()));
    return button;
}

} // namespace

QueuePanelView::QueuePanelView(QWidget* parent)
    : QWidget(parent)
{
    setObjectName(QStringLiteral("ctQueuePanelView"));
    setStyleSheet(QStringLiteral("QWidget#ctQueuePanelView { background: transparent; }"));

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);

    auto* header = new QWidget(this);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(CTSpacing::Lg, CTSpacing::Sm, CTSpacing::Lg, CTSpacing::Sm);
    m_countText = ui::secondaryLabel(QString());
    headerLayout->addWidget(m_countText);
    headerLayout->addStretch(1);
    auto* clear = makeGlyphButton(QStringLiteral("\uE74D"), QStringLiteral("清空队列"), header, 14);
    connect(clear, &QPushButton::clicked, this, [] { PlayerController::shared().clearQueue(); });
    headerLayout->addWidget(clear);
    auto* close = makeGlyphButton(QStringLiteral("\uE711"), L10n::Common::Close, header, 14);
    connect(close, &QPushButton::clicked, this, [] { AppState::shared().setShowQueue(false); });
    headerLayout->addWidget(close);
    root->addWidget(header);

    auto* body = new QWidget(this);
    auto* bodyLayout = new QVBoxLayout(body);
    bodyLayout->setContentsMargins(0, 0, 0, 0);
    bodyLayout->setSpacing(0);

    m_list = new QListWidget(body);
    m_list->setFrameShape(QFrame::NoFrame);
    m_list->setSelectionMode(QAbstractItemView::SingleSelection);
    m_list->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
    m_list->setContextMenuPolicy(Qt::CustomContextMenu);
    m_list->setStyleSheet(QStringLiteral("QListWidget { background: transparent; border: none; }"
                                         "QListWidget::item { border: none; }"
                                         "QListWidget::item:selected { background: %1; }")
                              .arg(CTColors::overlay().name()));
    connect(m_list, &QListWidget::itemDoubleClicked, this,
        [this](QListWidgetItem* item) { activateRow(m_list->row(item)); });
    connect(m_list, &QListWidget::customContextMenuRequested, this,
        [this](const QPoint& position) { showContextMenu(position); });
    connect(m_list, &QListWidget::itemClicked, this, [this](QListWidgetItem* item) {
        if (m_syncing || item == nullptr) return;
        const int row = m_list->row(item);
        const QList<QueueItem>& items = PlayerController::shared().queue().items;
        if (row < 0 || row >= items.size()) return;
        PlayerController::shared().jumpTo(items.at(row).id);
    });
    bodyLayout->addWidget(m_list);

    m_emptyText = ui::secondaryLabel(QStringLiteral("队列为空"));
    m_emptyText->setAlignment(Qt::AlignCenter);
    bodyLayout->addWidget(m_emptyText, 1, Qt::AlignCenter);
    root->addWidget(body, 1);

    m_queueObserver = PlayerController::shared().onQueueChanged.subscribe([this] { scheduleRefresh(); });
    m_songObserver = PlayerController::shared().onSongChanged.subscribe([this] { scheduleRefresh(); });
    refresh();
}

QueuePanelView::~QueuePanelView()
{
    PlayerController::shared().onQueueChanged.unsubscribe(m_queueObserver);
    PlayerController::shared().onSongChanged.unsubscribe(m_songObserver);
}

void QueuePanelView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    refresh();
}

void QueuePanelView::scheduleRefresh()
{
    if (m_refreshScheduled) return;
    m_refreshScheduled = true;
    QMetaObject::invokeMethod(
        this,
        [this] {
            m_refreshScheduled = false;
            refresh();
        },
        Qt::QueuedConnection);
}

void QueuePanelView::refresh()
{
    PlayerController& player = PlayerController::shared();
    const QList<QueueItem> items = player.queue().items;
    m_countText->setText(QStringLiteral("%1 首").arg(items.size()));
    m_emptyText->setVisible(items.isEmpty());
    m_list->setVisible(!items.isEmpty());

    m_syncing = true;
    m_list->clear();
    const QUuid currentID = player.queue().currentItem() != nullptr
        ? player.queue().currentItem()->id
        : QUuid();
    for (const QueueItem& item : items) {
        const bool isCurrent = item.id == currentID;
        auto* rowItem = new QListWidgetItem(m_list);
        rowItem->setSizeHint(QSize(0, 52));

        auto* widget = new QWidget(m_list);
        auto* layout = new QHBoxLayout(widget);
        layout->setContentsMargins(CTSpacing::Sm, 4, CTSpacing::Sm, 4);
        layout->setSpacing(CTSpacing::Sm);

        auto* cover = new CoverImage(widget);
        cover->setFixedSize(36, 36);
        cover->setCornerRadius(CTRadius::Small);
        cover->setCoverURL(item.song.coverURL, 72);
        layout->addWidget(cover, 0, Qt::AlignVCenter);

        auto* info = new QWidget(widget);
        auto* infoLayout = new QVBoxLayout(info);
        infoLayout->setContentsMargins(0, 0, 0, 0);
        infoLayout->setSpacing(2);
        auto* title = ui::titleLabel(item.song.title, CTTypography::Body, isCurrent);
        title->setStyleSheet(QStringLiteral("color: %1;").arg(
            isCurrent ? CTColors::accent().name() : CTColors::textPrimary().name()));
        infoLayout->addWidget(title);
        infoLayout->addWidget(ui::secondaryLabel(item.song.artistNames()));
        layout->addWidget(info, 1);

        auto* duration = ui::secondaryLabel(CTFormatting::time(item.song.duration));
        layout->addWidget(duration, 0, Qt::AlignVCenter);

        auto* remove = makeGlyphButton(QStringLiteral("\uE711"), QStringLiteral("从队列移除"), widget, 12);
        const QUuid itemID = item.id;
        connect(remove, &QPushButton::clicked, this,
            [itemID] { PlayerController::shared().removeFromQueue(itemID); });
        layout->addWidget(remove, 0, Qt::AlignVCenter);

        m_list->setItemWidget(rowItem, widget);
        if (isCurrent) m_list->setCurrentItem(rowItem);
    }
    m_syncing = false;
}

void QueuePanelView::activateRow(int row)
{
    const QList<QueueItem>& items = PlayerController::shared().queue().items;
    if (row < 0 || row >= items.size()) return;
    PlayerController::shared().jumpTo(items.at(row).id);
}

void QueuePanelView::showContextMenu(const QPoint& position)
{
    QListWidgetItem* item = m_list->itemAt(position);
    if (item == nullptr) return;
    const int row = m_list->row(item);
    const QList<QueueItem> items = PlayerController::shared().queue().items;
    if (row < 0 || row >= items.size()) return;
    const QueueItem entry = items.at(row);

    QMenu menu(this);
    menu.addAction(QStringLiteral("立即播放"), [id = entry.id] {
        PlayerController::shared().jumpTo(id);
    });
    menu.addAction(QStringLiteral("上移"), [this, row] { moveItem(row, -1); });
    menu.addAction(QStringLiteral("下移"), [this, row] { moveItem(row, 1); });
    menu.addAction(QStringLiteral("从队列移除"), [id = entry.id] {
        PlayerController::shared().removeFromQueue(id);
    });
    menu.exec(m_list->viewport()->mapToGlobal(position));
}

void QueuePanelView::moveItem(int row, int delta)
{
    const QList<QueueItem>& items = PlayerController::shared().queue().items;
    const int target = row + delta;
    if (row < 0 || row >= items.size() || target < 0 || target >= items.size()) return;
    PlayerController::shared().moveQueueItems(row, target);
}

CT_REGISTER_OVERLAY(OverlayKind::Queue, QueuePanelView);

} // namespace ct
