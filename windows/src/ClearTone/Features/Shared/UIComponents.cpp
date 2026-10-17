#include "Features/Shared/UIComponents.h"

#include "App/AppState.h"
#include "DesignSystem/CoverImage.h"
#include "DesignSystem/CoverImageLoader.h"
#include "DesignSystem/L10n.h"
#include "DesignSystem/SmoothText.h"
#include "Playback/PlayerController.h"

#include <QApplication>
#include <QHideEvent>
#include <QKeyEvent>
#include "DesignSystem/FlowLayout.h"
#include <QHBoxLayout>
#include <QLabel>
#include <QListWidget>
#include <QMenu>
#include <QMouseEvent>
#include <QPainter>
#include <QPainterPath>
#include <QProgressBar>
#include <QResizeEvent>
#include <QScrollArea>
#include <QStyledItemDelegate>
#include <QStyle>
#include <QTimer>
#include <QVBoxLayout>

namespace ct::ui {

namespace {

class SquareCover : public CoverImage {
public:
    explicit SquareCover(int side, QWidget* parent) : CoverImage(parent), m_side(side)
    {
        QSizePolicy policy(QSizePolicy::Expanding, QSizePolicy::Preferred);
        policy.setHeightForWidth(true);
        setSizePolicy(policy);
    }
    QSize sizeHint() const override { return QSize(m_side, m_side); }
    QSize minimumSizeHint() const override { return QSize(80, 80); }
    int heightForWidth(int width) const override { return width; }
private:
    int m_side;
};

class DetailHeader : public QWidget {
public:
    DetailHeader(const std::optional<QString>& url, QWidget* info)
    {
        setObjectName(QStringLiteral("ctDetailHeader"));
        auto* row = new QHBoxLayout(this);
        row->setContentsMargins(24, 12, 24, 12);
        row->setSpacing(20);
        m_cover = new CoverImage(this);
        m_cover->setFixedSize(160, 160);
        m_cover->setCornerRadius(12);
        m_cover->setCoverURL(url, 320);
        row->addWidget(m_cover, 0, Qt::AlignTop);
        row->addWidget(info, 1);
    }
protected:
    void resizeEvent(QResizeEvent* event) override
    {
        QWidget::resizeEvent(event);
        const int side = qBound(96, (width() - 96) / 4, 160);
        if (m_cover->width() != side) m_cover->setFixedSize(side, side);
    }
private:
    CoverImage* m_cover = nullptr;
};

QString secondaryStyle()
{
    return QStringLiteral("color: %1;").arg(CTColors::textSecondary().name());
}

} // namespace

ElidedLabel::ElidedLabel(const QString& text, QWidget* parent)
    : QLabel(parent)
{
    setTextFormat(Qt::PlainText);
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
    setFullText(text);
}

void ElidedLabel::setFullText(const QString& text)
{
    m_fullText = text;
    setToolTip(text);
    updateElided();
    updateGeometry();
}

QSize ElidedLabel::sizeHint() const
{
    const QFontMetrics metrics(font());
    return QSize(metrics.horizontalAdvance(m_fullText), metrics.height());
}

QSize ElidedLabel::minimumSizeHint() const
{
    return QSize(0, QLabel::minimumSizeHint().height());
}

void ElidedLabel::resizeEvent(QResizeEvent* event)
{
    QLabel::resizeEvent(event);
    updateElided();
}

void ElidedLabel::changeEvent(QEvent* event)
{
    QLabel::changeEvent(event);
    if (event->type() == QEvent::FontChange || event->type() == QEvent::ApplicationFontChange
        || event->type() == QEvent::StyleChange) {
        updateElided();
        updateGeometry();
    }
}

void ElidedLabel::updateElided()
{
    const int available = contentsRect().width();
    if (available <= 0 || m_fullText.isEmpty()) {
        QLabel::setText(m_fullText);
        return;
    }
    QLabel::setText(fontMetrics().elidedText(m_fullText, Qt::ElideRight, available));
}

QLabel* titleLabel(const QString& text, double size, bool bold)
{
    auto* label = new QLabel(text);
    label->setTextFormat(Qt::PlainText);
    QString style = QStringLiteral("color: %1; font-size: %2px;")
                        .arg(CTColors::textPrimary().name())
                        .arg(size);
    if (bold) style += QStringLiteral("font-weight: 600;");
    label->setStyleSheet(style);
    return label;
}

QLabel* secondaryLabel(const QString& text)
{
    auto* label = new QLabel(text);
    label->setTextFormat(Qt::PlainText);
    label->setStyleSheet(secondaryStyle());
    return label;
}

ElidedLabel* titleElidedLabel(const QString& text, double size, bool bold)
{
    auto* label = new ElidedLabel(text);
    QString style = QStringLiteral("color: %1; font-size: %2px;")
                        .arg(CTColors::textPrimary().name())
                        .arg(size);
    if (bold) style += QStringLiteral("font-weight: 600;");
    label->setStyleSheet(style);
    return label;
}

ElidedLabel* secondaryElidedLabel(const QString& text)
{
    auto* label = new ElidedLabel(text);
    label->setStyleSheet(secondaryStyle());
    return label;
}

QWidget* detailHeader(const std::optional<QString>& coverURL, QWidget* info)
{
    return new DetailHeader(coverURL, info);
}

QWidget* cardGrid(const QList<QWidget*>& cards)
{
    auto* container = new QWidget();
    auto* flow = new FlowLayout(container);
    for (QWidget* card : cards) flow->addWidget(card);
    return container;
}

QWidget* headerRow(const QString& title, QWidget* trailing)
{
    auto* container = new QWidget();
    auto* layout = new QHBoxLayout(container);
    layout->setContentsMargins(0, 6, 0, 6);
    auto* label = titleLabel(title, CTTypography::SectionTitle, true);
    layout->addWidget(label);
    layout->addStretch(1);
    if (trailing) layout->addWidget(trailing);
    return container;
}

QPushButton* linkButton(const QString& text, std::function<void()> action)
{
    auto* button = new QPushButton(text);
    button->setFlat(true);
    button->setCursor(Qt::PointingHandCursor);
    button->setProperty("ctRole", "link");
    QObject::connect(button, &QPushButton::clicked, [action = std::move(action)] {
        if (action) action();
    });
    return button;
}

QPushButton* accentButton(const QString& text)
{
    auto* button = new QPushButton(text);
    button->setCursor(Qt::PointingHandCursor);
    button->setProperty("ctRole", "primary");
    return button;
}

QPushButton* ghostButton(const QString& text)
{
    auto* button = new QPushButton(text);
    button->setCursor(Qt::PointingHandCursor);
    button->setProperty("ctRole", "ghost");
    return button;
}

QWidget* statusPanel(const QString& text, bool showSpinner)
{
    auto* container = new QFrame();
    container->setObjectName(QStringLiteral("ctStatusPanel"));
    container->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Maximum);
    auto* layout = new QVBoxLayout(container);
    layout->setContentsMargins(24, 24, 24, 24);
    layout->setSpacing(10);
    layout->setAlignment(Qt::AlignCenter);
    if (showSpinner) {
        auto* progress = new QProgressBar(container);
        progress->setRange(0, 0);
        progress->setFixedWidth(160);
        progress->setTextVisible(false);
        layout->addWidget(progress, 0, Qt::AlignHCenter);
    }
    auto* label = secondaryLabel(text);
    label->setWordWrap(true);
    label->setAlignment(Qt::AlignCenter);
    label->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
    layout->addWidget(label);
    return container;
}

QWidget* errorPanel(const QString& message, std::function<void()> retry)
{
    auto* container = new QFrame();
    container->setObjectName(QStringLiteral("ctStatusPanel"));
    container->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Maximum);
    auto* layout = new QVBoxLayout(container);
    layout->setContentsMargins(24, 24, 24, 24);
    layout->setSpacing(10);
    layout->setAlignment(Qt::AlignCenter);
    auto* label = secondaryLabel(message);
    label->setWordWrap(true);
    label->setAlignment(Qt::AlignCenter);
    label->setMaximumWidth(420);
    label->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
    layout->addWidget(label);
    auto* button = accentButton(L10n::Common::Retry);
    QObject::connect(button, &QPushButton::clicked, [retry = std::move(retry)] {
        if (retry) retry();
    });
    layout->addWidget(button, 0, Qt::AlignHCenter);
    return container;
}

QFrame* separator()
{
    auto* frame = new QFrame();
    frame->setFrameShape(QFrame::HLine);
    frame->setFixedHeight(1);
    frame->setStyleSheet(QStringLiteral("background: %1; border: none;").arg(CTColors::overlay().name()));
    return frame;
}

QScrollArea* scrollWrapper(QWidget* content)
{
    auto* area = new QScrollArea();
    area->setWidgetResizable(true);
    area->setFrameShape(QFrame::NoFrame);
    area->setWidget(content);
    content->setAutoFillBackground(false);
    area->viewport()->setAutoFillBackground(false);
    area->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    area->setStyleSheet(QStringLiteral("QScrollArea { background: transparent; }"));
    return area;
}

CardButton::CardButton(QWidget* parent)
    : QFrame(parent)
{
    setObjectName(QStringLiteral("ctCardButton"));
    setCursor(Qt::PointingHandCursor);
    setFocusPolicy(Qt::StrongFocus);
}

void CardButton::setHighlighted(bool highlighted)
{
    setProperty("highlighted", highlighted);
    style()->unpolish(this);
    style()->polish(this);
    update();
}

void CardButton::keyPressEvent(QKeyEvent* event)
{
    if (event->key() == Qt::Key_Return || event->key() == Qt::Key_Space) {
        if (onClicked) onClicked();
        event->accept();
        return;
    }
    QFrame::keyPressEvent(event);
}

void CardButton::mouseReleaseEvent(QMouseEvent* event)
{
    if (event->button() == Qt::LeftButton && rect().contains(event->position().toPoint())) {
        if (onClicked) onClicked();
    }
    QFrame::mouseReleaseEvent(event);
}

void CardButton::enterEvent(QEnterEvent* event) { QFrame::enterEvent(event); }
void CardButton::leaveEvent(QEvent* event) { QFrame::leaveEvent(event); }

namespace {

QWidget* makeCard(const QString& coverURL, double coverSize, double radius, const QString& title,
    const QString& subtitle, std::function<void()> onClick, double width)
{
    auto* card = new CardButton();
    if (width >= 160) {
        card->setMinimumWidth(144);
        card->setMaximumWidth(216);
        card->setProperty("ctFluidCard", true);
    } else {
        card->setFixedWidth(static_cast<int>(width));
    }
    card->setAccessibleName(title);
    auto* layout = new QVBoxLayout(card);
    layout->setContentsMargins(8, 8, 8, 10);
    layout->setSpacing(8);

    const int imageSide = static_cast<int>(qMin(coverSize, width - 16));
    auto* cover = new SquareCover(imageSide, card);
    cover->setCornerRadius(radius);
    cover->setCoverURL(coverURL, static_cast<int>(coverSize) * 2);
    layout->addWidget(cover);

    auto* titleLabel = new ElidedLabel(title, card);
    titleLabel->setAlignment(Qt::AlignLeft);
    titleLabel->setStyleSheet(QStringLiteral("color: %1; font-size: %2px; font-weight: 600;")
                                  .arg(CTColors::textPrimary().name())
                                  .arg(CTTypography::Body));
    layout->addWidget(titleLabel);

    auto* subtitleLabel = new ElidedLabel(subtitle, card);
    subtitleLabel->setAlignment(Qt::AlignLeft);
    subtitleLabel->setStyleSheet(secondaryStyle());
    layout->addWidget(subtitleLabel);

    card->onClicked = std::move(onClick);
    return card;
}

} // namespace

QWidget* playlistCard(const Playlist& playlist, std::function<void(const Playlist&)> onClick, double width)
{
    const Playlist copy = playlist;
    return makeCard(playlist.coverURL.value_or(QString()), width, CTRadius::Medium,
        playlist.name, QStringLiteral("%1 首").arg(playlist.trackCount),
        [onClick, copy] {
            if (onClick) onClick(copy);
        },
        width);
}

QWidget* albumCard(const Album& album, std::function<void(const Album&)> onClick, double width)
{
    const Album copy = album;
    return makeCard(album.coverURL.value_or(QString()), width, CTRadius::Medium, album.name,
        QStringLiteral("专辑"),
        [onClick, copy] {
            if (onClick) onClick(copy);
        },
        width);
}

QWidget* artistCard(const Artist& artist, std::function<void(const Artist&)> onClick, double width)
{
    const Artist copy = artist;
    return makeCard(artist.avatarURL.value_or(QString()), width, width / 2, artist.name,
        QString(),
        [onClick, copy] {
            if (onClick) onClick(copy);
        },
        width);
}

} // namespace ct::ui

namespace ct {

namespace {

constexpr int rowCoverDecodeWidth = 64;
constexpr int maxCachedRowPixmaps = 48;

class SongRowDelegate final : public QStyledItemDelegate {
public:
    explicit SongRowDelegate(SongListView* view)
        : QStyledItemDelegate(view)
        , m_view(view)
    {
    }

    void paint(QPainter* painter, const QStyleOptionViewItem& option,
        const QModelIndex& modelIndex) const override
    {
        painter->save();
        painter->setRenderHint(QPainter::Antialiasing, true);
        painter->setRenderHint(QPainter::TextAntialiasing, true);

        const QRect rowRect = option.rect;
        if (!modelIndex.data(Qt::UserRole).isValid()) {
            painter->setPen(CTColors::textSecondary());
            painter->setFont(option.font);
            painter->drawText(rowRect, Qt::AlignCenter, m_view->emptyText());
            painter->restore();
            return;
        }

        const int index = modelIndex.data(Qt::UserRole).toInt();
        const QList<Song>& songs = m_view->songs();
        if (index < 0 || index >= songs.size()) {
            painter->restore();
            return;
        }
        const Song& song = songs.at(index);

        if (option.state.testFlag(QStyle::State_Selected)
            || option.state.testFlag(QStyle::State_MouseOver)) {
            QPainterPath bgPath;
            bgPath.addRoundedRect(rowRect.adjusted(0, 1, 0, -1), 8, 8);
            painter->fillPath(bgPath, CTColors::overlay());
        }

        const QRect inner = rowRect.adjusted(8, 8, -16, -8);
        int left = inner.left();

        const auto currentSong = PlayerController::shared().currentSong();
        const bool playing = currentSong.has_value() && currentSong->id == song.id;

        const QRect indexRect(left, inner.top(), 30, inner.height());
        left += 30 + 8;
        if (playing || m_view->showIndex()) {
            painter->setPen(playing ? CTColors::accent() : CTColors::textSecondary());
            painter->setFont(option.font);
            painter->drawText(indexRect, Qt::AlignCenter,
                playing ? QStringLiteral("▶") : QString::number(index + 1));
        }

        const int coverSide = 42;
        const QRectF coverRect(left, rowRect.top() + (rowRect.height() - coverSide) / 2.0,
            coverSide, coverSide);
        left += coverSide + 8;

        {
            painter->save();
            QPainterPath clip;
            clip.addRoundedRect(coverRect, 7, 7);
            painter->setClipPath(clip);
            painter->fillRect(coverRect, QColor(128, 128, 128, 0x33));
            const QPixmap pixmap = m_view->coverPixmapFor(song.coverURL.value_or(QString()));
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
                QFont iconFont = option.font;
                iconFont.setPointSizeF(10.5);
                painter->setFont(iconFont);
                painter->drawText(coverRect, Qt::AlignCenter, QStringLiteral("♪"));
            }
            painter->restore();
        }

        int right = inner.right() + 1;
        const QRect durationRect(right - 48, inner.top(), 48, inner.height());
        right -= 48 + 8;
        ui::drawSmoothText(painter, durationRect, CTFormatting::time(song.duration), option.font,
            CTColors::textSecondary(), Qt::AlignRight | Qt::AlignVCenter);

        if (!song.isPlayable) {
            const QString reason = song.unavailableReason.value_or(QString());
            if (!reason.isEmpty()) {
                const QFontMetrics metrics(option.font);
                const QString elidedReason = metrics.elidedText(reason, Qt::ElideRight, 120);
                const int reasonWidth = qBound(48, metrics.horizontalAdvance(elidedReason) + 8, 128);
                const QRect reasonRect(right - reasonWidth, inner.top(), reasonWidth, inner.height());
                right -= reasonWidth + 8;
                ui::drawSmoothText(painter, reasonRect, elidedReason, option.font,
                    CTColors::textSecondary(), Qt::AlignRight | Qt::AlignVCenter);
            }
        }

        const QRect likeRect(right - 18, inner.top(), 18, inner.height());
        right -= 18 + 8;
        if (AppState::shared().isLiked(song.id)) {
            painter->setPen(CTColors::accent());
            painter->drawText(likeRect, Qt::AlignCenter, QStringLiteral("♥"));
        }

        const int textWidth = qMax(0, right - left);
        if (textWidth > 0) {
            QFont titleFont = option.font;
            titleFont.setPixelSize(static_cast<int>(CTTypography::Body));
            titleFont.setWeight(song.isPlayable ? QFont::DemiBold : QFont::Normal);
            const QFontMetrics titleMetrics(titleFont);
            const QFontMetrics artistMetrics(option.font);

            const int totalTextHeight = titleMetrics.height() + 2 + artistMetrics.height();
            const int textTop = rowRect.top() + (rowRect.height() - totalTextHeight) / 2;
            const QRect titleRect(left, textTop, textWidth, titleMetrics.height());
            const QRect artistRect(left, textTop + titleMetrics.height() + 2, textWidth,
                artistMetrics.height());

            ui::drawSmoothText(painter, titleRect,
                titleMetrics.elidedText(song.title, Qt::ElideRight, textWidth), titleFont,
                song.isPlayable ? CTColors::textPrimary() : CTColors::textSecondary(),
                Qt::AlignLeft | Qt::AlignVCenter);
            ui::drawSmoothText(painter, artistRect,
                artistMetrics.elidedText(song.artistNames(), Qt::ElideRight, textWidth), option.font,
                CTColors::textSecondary(), Qt::AlignLeft | Qt::AlignVCenter);
        }

        painter->restore();
    }

private:
    SongListView* m_view = nullptr;
};

} // namespace

SongListView::SongListView(QWidget* parent)
    : QWidget(parent)
    , m_list(new QListWidget(this))
    , m_coverCts(std::make_shared<CancellationTokenSource>())
{
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    m_list->setFrameShape(QFrame::NoFrame);
    m_list->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    m_list->setSpacing(2);
    m_list->setUniformItemSizes(true);
    m_list->setSelectionMode(QAbstractItemView::SingleSelection);
    m_list->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
    m_list->setContextMenuPolicy(Qt::CustomContextMenu);
    m_list->setItemDelegate(new SongRowDelegate(this));
    m_list->setStyleSheet(QStringLiteral("QListWidget { background: transparent; border: none; }"
                                         "QListWidget::item { border: none; border-radius: 8px; }"));
    layout->addWidget(m_list);

    QObject::connect(m_list, &QListWidget::itemDoubleClicked, this, [this](QListWidgetItem* item) {
        activateRow(m_list->row(item));
    });
    QObject::connect(m_list, &QListWidget::customContextMenuRequested, this, [this](const QPoint& position) {
        showContextMenu(position);
    });

    m_appObserver = AppState::shared().changed.subscribe([this] { refreshDynamic(); });
    m_stateObserver = PlayerController::shared().onStateChanged.subscribe([this] { refreshDynamic(); });
    m_songObserver = PlayerController::shared().onSongChanged.subscribe([this] { refreshDynamic(); });
}

SongListView::~SongListView()
{
    if (m_coverCts) m_coverCts->cancel();
    AppState::shared().changed.unsubscribe(m_appObserver);
    PlayerController::shared().onStateChanged.unsubscribe(m_stateObserver);
    PlayerController::shared().onSongChanged.unsubscribe(m_songObserver);
}

void SongListView::hideEvent(QHideEvent* event)
{
    QWidget::hideEvent(event);
    if (m_coverCts) m_coverCts->cancel();
    m_coverCts = std::make_shared<CancellationTokenSource>();
    ++m_coverGeneration;
    m_inFlightCovers.clear();
    m_rowPixmaps.clear();
}

QPixmap SongListView::coverPixmapFor(const QString& url)
{
    if (url.isEmpty()) return QPixmap();
    if (const auto found = m_rowPixmaps.constFind(url); found != m_rowPixmaps.constEnd()) {
        return *found;
    }
    if (const auto cached = CoverImageLoader::shared().peekMemory(url, rowCoverDecodeWidth)) {
        if (m_rowPixmaps.size() >= maxCachedRowPixmaps) m_rowPixmaps.clear();
        QPixmap pixmap = QPixmap::fromImage(*cached);
        m_rowPixmaps.insert(url, pixmap);
        return pixmap;
    }
    if (!m_inFlightCovers.contains(url)) {
        m_inFlightCovers.insert(url);
        if (!m_coverCts) m_coverCts = std::make_shared<CancellationTokenSource>();
        detach(fetchCoverAsync(QPointer<SongListView>(this), url, m_coverGeneration, m_coverCts->token()));
    }
    return QPixmap();
}

Task<void> SongListView::fetchCoverAsync(
    QPointer<SongListView> self, QString url, quint64 generation, CancellationToken token)
{
    const auto image = co_await CoverImageLoader::shared().load(url, rowCoverDecodeWidth, token);
    if (!self || generation != self->m_coverGeneration) co_return;
    self->m_inFlightCovers.remove(url);
    if (!image) co_return;
    if (self->m_rowPixmaps.size() >= maxCachedRowPixmaps) self->m_rowPixmaps.clear();
    self->m_rowPixmaps.insert(url, QPixmap::fromImage(*image));
    if (self->m_list && self->m_list->viewport()) {
        self->m_list->viewport()->update();
    }
}

void SongListView::setSongs(const QList<Song>& songs)
{
    bool isPrefixExtension = !m_songs.isEmpty() && songs.size() >= m_songs.size()
        && m_list->count() == m_songs.size();
    if (isPrefixExtension) {
        for (int i = 0; i < m_songs.size(); ++i) {
            if (m_songs.at(i).id != songs.at(i).id) {
                isPrefixExtension = false;
                break;
            }
        }
    }
    if (isPrefixExtension) {
        const int previousSize = m_songs.size();
        m_songs = songs;
        for (int index = previousSize; index < m_songs.size(); ++index) {
            appendItem(index);
        }
        refreshDynamic();
        return;
    }

    m_songs = songs;
    rebuild();
}

void SongListView::setShowIndex(bool showIndex)
{
    if (m_showIndex == showIndex) return;
    m_showIndex = showIndex;
    refreshDynamic();
}

int SongListView::contentHeight() const
{
    if (m_songs.isEmpty()) return m_emptyText.isEmpty() ? 0 : 120;
    return m_songs.size() * (m_rowHeight + 2 * m_list->spacing()) + 2 * m_list->frameWidth();
}

void SongListView::setRowHeight(int height)
{
    const int clamped = qMax(52, height);
    if (m_rowHeight == clamped) return;
    m_rowHeight = clamped;
    rebuild();
}

void SongListView::setEmptyText(const QString& text)
{
    m_emptyText = text;
    if (m_songs.isEmpty()) rebuild();
}

void SongListView::appendItem(int index)
{
    const Song& song = m_songs.at(index);
    auto* item = new QListWidgetItem(m_list);
    item->setSizeHint(QSize(0, m_rowHeight));
    item->setData(Qt::UserRole, index);
    item->setToolTip(QStringLiteral("%1 — %2").arg(song.title, song.artistNames()));
    if (!song.isPlayable) {
        item->setFlags(item->flags() & ~Qt::ItemIsEnabled);
    }
}

void SongListView::rebuild()
{
    m_list->clear();

    if (m_songs.isEmpty()) {
        if (m_emptyText.isEmpty()) return;
        auto* item = new QListWidgetItem(m_list);
        item->setFlags(Qt::NoItemFlags);
        item->setSizeHint(QSize(0, 120));
        return;
    }

    for (int index = 0; index < m_songs.size(); ++index) {
        appendItem(index);
    }
    refreshDynamic();
}

void SongListView::refreshDynamic()
{
    if (m_list && m_list->viewport()) {
        m_list->viewport()->update();
    }
}

void SongListView::activateRow(int row)
{
    if (row < 0 || row >= m_songs.size()) return;
    const Song& song = m_songs[row];
    if (!song.isPlayable) return;
    PlayerController::shared().playSongs(m_songs, row);
}

void SongListView::showContextMenu(const QPoint& position)
{
    QListWidgetItem* item = m_list->itemAt(position);
    if (!item) return;
    const int index = item->data(Qt::UserRole).toInt();
    if (index < 0 || index >= m_songs.size()) return;
    const Song song = m_songs[index];
    AppState& app = AppState::shared();

    QMenu menu(this);
    menu.addAction(QStringLiteral("立即播放"), [song] {
        PlayerController::shared().playSong(song);
    });
    menu.addAction(QStringLiteral("下一首播放"), [song] {
        PlayerController::shared().insertNext(song);
    });
    menu.addAction(QStringLiteral("添加到队列"), [song] {
        PlayerController::shared().appendToQueue(song);
    });
    menu.addAction(app.isLiked(song.id) ? QStringLiteral("取消喜欢") : QStringLiteral("喜欢"), [&app, song] {
        detach(app.toggleLike(song));
    });
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
    if (song.album && !song.album->id.isEmpty()) {
        menu.addAction(QStringLiteral("打开专辑"), [&app, song] {
            app.openAlbum(song.album->id);
        });
    }
    if (!song.artists.isEmpty()) {
        menu.addAction(QStringLiteral("打开歌手"), [&app, song] {
            app.openArtist(song.artists.first().id);
        });
    }
    menu.exec(m_list->viewport()->mapToGlobal(position));
}

} // namespace ct
