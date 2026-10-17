#include "Features/NowPlaying/QueuePanelView.h"

#include "App/AppState.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImageLoader.h"
#include "DesignSystem/L10n.h"
#include "DesignSystem/SmoothText.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Playback/PlayerController.h"

#include <QEvent>
#include <QFrame>
#include <QHBoxLayout>
#include <QHideEvent>
#include <QLabel>
#include <QListWidget>
#include <QMenu>
#include <QMetaObject>
#include <QMouseEvent>
#include <QPainter>
#include <QPainterPath>
#include <QPushButton>
#include <QStyledItemDelegate>
#include <QVBoxLayout>

namespace ct {

namespace {

constexpr int queueCoverDecodeWidth = 64;
constexpr int maxCachedQueuePixmaps = 48;

QPushButton* makeGlyphButton(const QString& glyph, const QString& tip, QWidget* parent, double size)
{
    auto* button = new QPushButton(glyph, parent);
    button->setFlat(true);
    button->setCursor(Qt::PointingHandCursor);
    button->setToolTip(tip);
    button->setFixedSize(28, 28);
    button->setStyleSheet(QStringLiteral(
        "QPushButton { background: transparent; border: none; color: %1; font-size: %2px;"
        " font-family: 'lucide'; }"
        "QPushButton:hover { background: %3; border-radius: 6px; }")
                              .arg(CTColors::textPrimary().name())
                              .arg(size)
                              .arg(CTColors::overlay().name()));
    return button;
}

QRect removeButtonRect(const QRect& rowRect)
{
    const int margin = static_cast<int>(CTSpacing::Sm);
    return QRect(rowRect.right() - margin - 28 + 1,
        rowRect.top() + (rowRect.height() - 28) / 2, 28, 28);
}

class QueueRowDelegate final : public QStyledItemDelegate {
public:
    explicit QueueRowDelegate(QueuePanelView* view)
        : QStyledItemDelegate(view)
        , m_view(view)
    {
    }

    void paint(QPainter* painter, const QStyleOptionViewItem& option,
        const QModelIndex& index) const override
    {
        const QList<QueueItem>& items = PlayerController::shared().queue().items;
        const int row = index.row();
        if (row < 0 || row >= items.size()) return;
        const QueueItem& item = items.at(row);
        const QueueItem* current = PlayerController::shared().queue().currentItem();
        const bool isCurrent = current != nullptr && current->id == item.id;

        painter->save();
        painter->setRenderHint(QPainter::Antialiasing, true);
        painter->setRenderHint(QPainter::TextAntialiasing, true);

        const QRect rowRect = option.rect;
        if (option.state.testFlag(QStyle::State_Selected)
            || option.state.testFlag(QStyle::State_MouseOver)) {
            painter->fillRect(rowRect, CTColors::overlay());
        }

        const int spacing = static_cast<int>(CTSpacing::Sm);
        int left = rowRect.left() + spacing;
        const int coverSide = 36;
        const QRectF coverRect(left, rowRect.top() + (rowRect.height() - coverSide) / 2.0,
            coverSide, coverSide);
        left += coverSide + spacing;

        {
            painter->save();
            QPainterPath clip;
            clip.addRoundedRect(coverRect, CTRadius::Small, CTRadius::Small);
            painter->setClipPath(clip);
            painter->fillRect(coverRect, QColor(128, 128, 128, 0x33));
            const QPixmap pixmap = m_view->coverPixmapFor(item.song.coverURL.value_or(QString()));
            if (!pixmap.isNull() && !pixmap.size().isEmpty()) {
                const QSizeF target = coverRect.size();
                const QSizeF source = pixmap.size();
                const double scale = qMax(target.width() / source.width(),
                    target.height() / source.height());
                const QSizeF scaled = source * scale;
                const QRectF sourceRect(
                    QPointF((scaled.width() - target.width()) / scale / 2.0,
                        (scaled.height() - target.height()) / scale / 2.0),
                    QSizeF(target.width() / scale, target.height() / scale));
                painter->drawPixmap(coverRect, pixmap, sourceRect);
            } else {
                painter->setPen(CTColors::textSecondary());
                painter->setFont(option.font);
                painter->drawText(coverRect, Qt::AlignCenter, QStringLiteral("♪"));
            }
            painter->restore();
        }

        const QRect removeRect = removeButtonRect(rowRect);
        {
            QFont iconFont(QStringLiteral("lucide"));
            iconFont.setPixelSize(12);
            painter->setFont(iconFont);
            painter->setPen(CTColors::textSecondary());
            painter->drawText(removeRect, Qt::AlignCenter, QStringLiteral("\uE1B1"));
        }

        const QFontMetrics metrics(option.font);
        const QString durationText = CTFormatting::time(item.song.duration);
        const int durationWidth = qMax(38, metrics.horizontalAdvance(durationText) + 4);
        const QRect durationRect(removeRect.left() - spacing - durationWidth, rowRect.top(),
            durationWidth, rowRect.height());
        ui::drawSmoothText(painter, durationRect, durationText, option.font,
            CTColors::textSecondary(), Qt::AlignRight | Qt::AlignVCenter);

        const int textWidth = qMax(0, durationRect.left() - spacing - left);
        if (textWidth > 0) {
            QFont titleFont = option.font;
            titleFont.setPixelSize(static_cast<int>(CTTypography::Body));
            titleFont.setWeight(isCurrent ? QFont::DemiBold : QFont::Normal);
            const QFontMetrics titleMetrics(titleFont);
            const int totalHeight = titleMetrics.height() + 2 + metrics.height();
            const int textTop = rowRect.top() + (rowRect.height() - totalHeight) / 2;

            ui::drawSmoothText(painter, QRect(left, textTop, textWidth, titleMetrics.height()),
                titleMetrics.elidedText(item.song.title, Qt::ElideRight, textWidth), titleFont,
                isCurrent ? CTColors::accent() : CTColors::textPrimary(),
                Qt::AlignLeft | Qt::AlignVCenter);

            ui::drawSmoothText(painter,
                QRect(left, textTop + titleMetrics.height() + 2, textWidth, metrics.height()),
                metrics.elidedText(item.song.artistNames(), Qt::ElideRight, textWidth), option.font,
                CTColors::textSecondary(), Qt::AlignLeft | Qt::AlignVCenter);
        }

        painter->restore();
    }

    bool editorEvent(QEvent* event, QAbstractItemModel* model,
        const QStyleOptionViewItem& option, const QModelIndex& index) override
    {
        if (event->type() == QEvent::MouseButtonRelease) {
            auto* mouse = static_cast<QMouseEvent*>(event);
            if (mouse->button() == Qt::LeftButton
                && removeButtonRect(option.rect).contains(mouse->pos())) {
                const QList<QueueItem>& items = PlayerController::shared().queue().items;
                const int row = index.row();
                if (row >= 0 && row < items.size()) {
                    const QUuid id = items.at(row).id;
                    PlayerController::shared().removeFromQueue(id);
                    return true;
                }
            }
        }
        return QStyledItemDelegate::editorEvent(event, model, option, index);
    }

private:
    QueuePanelView* m_view = nullptr;
};

} // namespace

QueuePanelView::QueuePanelView(QWidget* parent)
    : QWidget(parent)
    , m_coverCts(std::make_shared<CancellationTokenSource>())
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
    auto* clear = makeGlyphButton(QStringLiteral("\uE18D"), QStringLiteral("清空队列"), header, 14);
    connect(clear, &QPushButton::clicked, this, [] { PlayerController::shared().clearQueue(); });
    headerLayout->addWidget(clear);
    auto* close = makeGlyphButton(QStringLiteral("\uE1B1"), L10n::Common::Close, header, 14);
    connect(close, &QPushButton::clicked, this, [] { AppState::shared().setShowQueue(false); });
    headerLayout->addWidget(close);
    root->addWidget(header);

    auto* body = new QWidget(this);
    auto* bodyLayout = new QVBoxLayout(body);
    bodyLayout->setContentsMargins(0, 0, 0, 0);
    bodyLayout->setSpacing(0);

    m_list = new QListWidget(body);
    m_list->setFrameShape(QFrame::NoFrame);
    m_list->setUniformItemSizes(true);
    m_list->setSelectionMode(QAbstractItemView::SingleSelection);
    m_list->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
    m_list->setContextMenuPolicy(Qt::CustomContextMenu);
    m_list->setItemDelegate(new QueueRowDelegate(this));
    m_list->setStyleSheet(QStringLiteral("QListWidget { background: transparent; border: none; }"
                                         "QListWidget::item { border: none; }"));
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

    m_queueObserver = PlayerController::shared().onQueueChanged.subscribe(
        [this] { scheduleRefresh(true); });
    m_songObserver = PlayerController::shared().onSongChanged.subscribe(
        [this] { scheduleRefresh(false); });
}

QueuePanelView::~QueuePanelView()
{
    if (m_coverCts) m_coverCts->cancel();
    PlayerController::shared().onQueueChanged.unsubscribe(m_queueObserver);
    PlayerController::shared().onSongChanged.unsubscribe(m_songObserver);
}

void QueuePanelView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    if (m_dirtyWhileHidden) {
        refresh();
    } else {
        updateSelectionOnly();
    }
}

void QueuePanelView::hideEvent(QHideEvent* event)
{
    QWidget::hideEvent(event);
    if (m_coverCts) m_coverCts->cancel();
    m_coverCts = std::make_shared<CancellationTokenSource>();
    ++m_coverGeneration;
    m_inFlightCovers.clear();
    m_rowPixmaps.clear();
    m_list->clear();
    m_dirtyWhileHidden = true;
}

QPixmap QueuePanelView::coverPixmapFor(const QString& url)
{
    if (url.isEmpty()) return QPixmap();
    if (const auto found = m_rowPixmaps.constFind(url); found != m_rowPixmaps.constEnd()) {
        return *found;
    }
    if (const auto cached = CoverImageLoader::shared().peekMemory(url, queueCoverDecodeWidth)) {
        if (m_rowPixmaps.size() >= maxCachedQueuePixmaps) m_rowPixmaps.clear();
        QPixmap pixmap = QPixmap::fromImage(*cached);
        m_rowPixmaps.insert(url, pixmap);
        return pixmap;
    }
    if (!m_inFlightCovers.contains(url)) {
        m_inFlightCovers.insert(url);
        if (!m_coverCts) m_coverCts = std::make_shared<CancellationTokenSource>();
        detach(fetchCoverAsync(
            QPointer<QueuePanelView>(this), url, m_coverGeneration, m_coverCts->token()));
    }
    return QPixmap();
}

Task<void> QueuePanelView::fetchCoverAsync(
    QPointer<QueuePanelView> self, QString url, quint64 generation, CancellationToken token)
{
    const auto image = co_await CoverImageLoader::shared().load(url, queueCoverDecodeWidth, token);
    if (!self || generation != self->m_coverGeneration) co_return;
    self->m_inFlightCovers.remove(url);
    if (!image) co_return;
    if (self->m_rowPixmaps.size() >= maxCachedQueuePixmaps) self->m_rowPixmaps.clear();
    self->m_rowPixmaps.insert(url, QPixmap::fromImage(*image));
    if (self->m_list && self->m_list->viewport()) {
        self->m_list->viewport()->update();
    }
}

void QueuePanelView::scheduleRefresh(bool structureChanged)
{
    m_pendingStructureRefresh |= structureChanged;
    if (!isVisible()) {
        if (structureChanged) m_dirtyWhileHidden = true;
        return;
    }
    if (m_refreshScheduled) return;
    m_refreshScheduled = true;
    QMetaObject::invokeMethod(
        this,
        [this] {
            m_refreshScheduled = false;
            const bool rebuildAll = m_pendingStructureRefresh || m_dirtyWhileHidden;
            m_pendingStructureRefresh = false;
            if (!isVisible()) {
                if (rebuildAll) m_dirtyWhileHidden = true;
                return;
            }
            if (rebuildAll) {
                refresh();
            } else {
                updateSelectionOnly();
            }
        },
        Qt::QueuedConnection);
}

void QueuePanelView::refresh()
{
    m_dirtyWhileHidden = false;
    PlayerController& player = PlayerController::shared();
    const QList<QueueItem>& items = player.queue().items;
    m_countText->setText(QStringLiteral("%1 首").arg(items.size()));
    m_emptyText->setVisible(items.isEmpty());
    m_list->setVisible(!items.isEmpty());

    m_syncing = true;
    m_list->clear();
    const QUuid currentID = player.queue().currentItem() != nullptr
        ? player.queue().currentItem()->id
        : QUuid();
    for (int i = 0; i < items.size(); ++i) {
        const QueueItem& item = items.at(i);
        auto* rowItem = new QListWidgetItem(m_list);
        rowItem->setSizeHint(QSize(0, 52));
        rowItem->setToolTip(QStringLiteral("%1 — %2").arg(item.song.title, item.song.artistNames()));
        if (item.id == currentID) m_list->setCurrentItem(rowItem);
    }
    m_syncing = false;
    if (m_list->viewport()) m_list->viewport()->update();
}

void QueuePanelView::updateSelectionOnly()
{
    PlayerController& player = PlayerController::shared();
    const QList<QueueItem>& items = player.queue().items;
    if (m_list->count() != items.size()) {
        refresh();
        return;
    }
    m_syncing = true;
    const QUuid currentID = player.queue().currentItem() != nullptr
        ? player.queue().currentItem()->id
        : QUuid();
    for (int i = 0; i < items.size(); ++i) {
        if (items.at(i).id == currentID) {
            m_list->setCurrentRow(i);
            break;
        }
    }
    m_syncing = false;
    if (m_list->viewport()) m_list->viewport()->update();
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
