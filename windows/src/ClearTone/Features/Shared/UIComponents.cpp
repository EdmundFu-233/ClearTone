#include "Features/Shared/UIComponents.h"

#include "App/AppState.h"
#include "DesignSystem/CoverImage.h"
#include "DesignSystem/L10n.h"
#include "Playback/PlayerController.h"

#include <QApplication>
#include <QHBoxLayout>
#include <QLabel>
#include <QListWidget>
#include <QMenu>
#include <QMouseEvent>
#include <QProgressBar>
#include <QResizeEvent>
#include <QScrollArea>
#include <QStyle>
#include <QTimer>
#include <QVBoxLayout>

namespace ct::ui {

namespace {

QString secondaryStyle()
{
    return QStringLiteral("color: %1;").arg(CTColors::textSecondary().name());
}

} // namespace

ElidedLabel::ElidedLabel(const QString& text, QWidget* parent)
    : QLabel(parent)
{
    setSizePolicy(QSizePolicy::Preferred, QSizePolicy::Preferred);
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
    button->setStyleSheet(
        QStringLiteral("QPushButton { color: %1; border: none; background: transparent; font-size: 12px; padding: 2px 6px; }")
            .arg(CTColors::textSecondary().name()));
    QObject::connect(button, &QPushButton::clicked, [action = std::move(action)] {
        if (action) action();
    });
    return button;
}

QPushButton* accentButton(const QString& text)
{
    auto* button = new QPushButton(text);
    button->setCursor(Qt::PointingHandCursor);
    button->setStyleSheet(QStringLiteral(
        "QPushButton { background: %1; color: white; border: none; border-radius: 6px; padding: 6px 18px; font-weight: 600; }"
        "QPushButton:hover { background: %1; }")
                              .arg(CTColors::accent().name()));
    return button;
}

QPushButton* ghostButton(const QString& text)
{
    auto* button = new QPushButton(text);
    button->setCursor(Qt::PointingHandCursor);
    button->setStyleSheet(
        QStringLiteral("QPushButton { background: transparent; color: %1; border: 1px solid %2; "
                       "border-radius: 6px; padding: 6px 16px; }")
            .arg(CTColors::textPrimary().name(), CTColors::overlay().name()));
    return button;
}

QWidget* statusPanel(const QString& text, bool showSpinner)
{
    auto* container = new QWidget();
    auto* layout = new QVBoxLayout(container);
    layout->setContentsMargins(0, 60, 0, 60);
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
    label->setAlignment(Qt::AlignCenter);
    layout->addWidget(label, 0, Qt::AlignHCenter);
    return container;
}

QWidget* errorPanel(const QString& message, std::function<void()> retry)
{
    auto* container = new QWidget();
    auto* layout = new QVBoxLayout(container);
    layout->setContentsMargins(0, 60, 0, 60);
    layout->setSpacing(10);
    layout->setAlignment(Qt::AlignCenter);
    auto* label = secondaryLabel(message);
    label->setWordWrap(true);
    label->setAlignment(Qt::AlignCenter);
    label->setMaximumWidth(420);
    layout->addWidget(label, 0, Qt::AlignHCenter);
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
    area->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    area->setStyleSheet(QStringLiteral("QScrollArea { background: transparent; }"));
    return area;
}

CardButton::CardButton(QWidget* parent)
    : QFrame(parent)
{
    setCursor(Qt::PointingHandCursor);
    setStyleSheet(QStringLiteral("CardButton { background: transparent; border-radius: 8px; }"));
}

void CardButton::setHighlighted(bool highlighted)
{
    setStyleSheet(QStringLiteral("CardButton { background: %1; border-radius: 8px; }")
                      .arg(highlighted ? CTColors::overlay().name() : QStringLiteral("transparent")));
}

void CardButton::mouseReleaseEvent(QMouseEvent* event)
{
    if (event->button() == Qt::LeftButton && rect().contains(event->position().toPoint())) {
        if (onClicked) onClicked();
    }
    QFrame::mouseReleaseEvent(event);
}

void CardButton::enterEvent(QEnterEvent* event)
{
    setStyleSheet(QStringLiteral("CardButton { background: %1; border-radius: 8px; }")
                      .arg(CTColors::overlay().name()));
    QFrame::enterEvent(event);
}

void CardButton::leaveEvent(QEvent* event)
{
    setStyleSheet(QStringLiteral("CardButton { background: transparent; border-radius: 8px; }"));
    QFrame::leaveEvent(event);
}

namespace {

QWidget* makeCard(const QString& coverURL, double coverSize, double radius, const QString& title,
    const QString& subtitle, std::function<void()> onClick, double width)
{
    auto* card = new CardButton();
    card->setFixedWidth(static_cast<int>(width));
    auto* layout = new QVBoxLayout(card);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(6);

    auto* cover = new CoverImage(card);
    cover->setFixedSize(static_cast<int>(coverSize), static_cast<int>(coverSize));
    cover->setCornerRadius(radius);
    cover->setCoverURL(coverURL, static_cast<int>(coverSize) * 2);
    layout->addWidget(cover, 0, Qt::AlignHCenter);

    auto* titleLabel = new ElidedLabel(title, card);
    titleLabel->setAlignment(Qt::AlignHCenter);
    titleLabel->setStyleSheet(QStringLiteral("color: %1; font-size: %2px; font-weight: 600;")
                                  .arg(CTColors::textPrimary().name())
                                  .arg(CTTypography::Body));
    layout->addWidget(titleLabel);

    auto* subtitleLabel = new ElidedLabel(subtitle, card);
    subtitleLabel->setAlignment(Qt::AlignHCenter);
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

SongListView::SongListView(QWidget* parent)
    : QWidget(parent)
    , m_list(new QListWidget(this))
{
    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    m_list->setFrameShape(QFrame::NoFrame);
    m_list->setSelectionMode(QAbstractItemView::SingleSelection);
    m_list->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
    m_list->setContextMenuPolicy(Qt::CustomContextMenu);
    m_list->setStyleSheet(QStringLiteral("QListWidget { background: transparent; border: none; }"
                                         "QListWidget::item { border: none; }"
                                         "QListWidget::item:selected { background: %1; }")
                              .arg(CTColors::overlay().name()));
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
    AppState::shared().changed.unsubscribe(m_appObserver);
    PlayerController::shared().onStateChanged.unsubscribe(m_stateObserver);
    PlayerController::shared().onSongChanged.unsubscribe(m_songObserver);
}

void SongListView::setSongs(const QList<Song>& songs)
{
    m_songs = songs;
    rebuild();
}

void SongListView::setShowIndex(bool showIndex)
{
    m_showIndex = showIndex;
    rebuild();
}

void SongListView::setRowHeight(int height)
{
    m_rowHeight = height;
    rebuild();
}

void SongListView::setEmptyText(const QString& text)
{
    m_emptyText = text;
    if (m_songs.isEmpty()) rebuild();
}

void SongListView::rebuild()
{
    m_list->clear();
    m_rows.clear();

    if (m_songs.isEmpty()) {
        if (m_emptyText.isEmpty()) return;
        auto* item = new QListWidgetItem(m_list);
        item->setFlags(Qt::NoItemFlags);
        item->setSizeHint(QSize(0, 120));
        auto* label = ui::secondaryLabel(m_emptyText);
        label->setAlignment(Qt::AlignCenter);
        m_list->setItemWidget(item, label);
        return;
    }

    for (int index = 0; index < m_songs.size(); ++index) {
        const Song& song = m_songs[index];
        Row row;
        row.item = new QListWidgetItem(m_list);
        row.item->setSizeHint(QSize(0, m_rowHeight));
        row.item->setData(Qt::UserRole, index);
        if (!song.isPlayable) {
            row.item->setFlags(row.item->flags() & ~Qt::ItemIsEnabled);
        }

        auto* widget = new QWidget(m_list);
        auto* layout = new QHBoxLayout(widget);
        layout->setContentsMargins(6, 4, 12, 4);
        layout->setSpacing(8);

        row.index = ui::secondaryLabel(m_showIndex ? QString::number(index + 1) : QString());
        row.index->setFixedWidth(30);
        row.index->setAlignment(Qt::AlignCenter);
        layout->addWidget(row.index);

        auto* cover = new CoverImage(widget);
        cover->setFixedSize(36, 36);
        cover->setCornerRadius(4);
        cover->setCoverURL(song.coverURL.value_or(QString()), 72);
        layout->addWidget(cover);

        auto* textColumn = new QWidget(widget);
        auto* textLayout = new QVBoxLayout(textColumn);
        textLayout->setContentsMargins(0, 0, 0, 0);
        textLayout->setSpacing(2);
        row.title = new ui::ElidedLabel(song.title, widget);
        row.title->setStyleSheet(QStringLiteral("color: %1; font-size: %2px; font-weight: %3;")
                                     .arg(song.isPlayable ? CTColors::textPrimary().name()
                                                          : CTColors::textSecondary().name())
                                     .arg(CTTypography::Body)
                                     .arg(song.isPlayable ? 600 : 400));
        textLayout->addWidget(row.title);
        row.artist = ui::secondaryElidedLabel(song.artistNames());
        textLayout->addWidget(row.artist);
        layout->addWidget(textColumn, 1);

        row.like = new QLabel(QStringLiteral("♥"), widget);
        row.like->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::accent().name()));
        row.like->setFixedWidth(18);
        layout->addWidget(row.like);

        row.reason = ui::secondaryLabel(song.unavailableReason.value_or(QString()));
        layout->addWidget(row.reason);

        row.duration = ui::secondaryLabel(CTFormatting::time(song.duration));
        row.duration->setFixedWidth(48);
        row.duration->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
        layout->addWidget(row.duration);

        m_list->setItemWidget(row.item, widget);
        m_rows.append(row);
    }
    refreshDynamic();
}

void SongListView::refreshDynamic()
{
    const QString playingID = PlayerController::shared().currentSong()
        ? PlayerController::shared().currentSong()->id
        : QString();
    const AppState& app = AppState::shared();
    for (int index = 0; index < m_rows.size(); ++index) {
        const Row& row = m_rows[index];
        if (!row.index) continue;
        const bool playing = !playingID.isEmpty() && m_songs[index].id == playingID;
        row.index->setText(playing ? QStringLiteral("▶")
                                   : (m_showIndex ? QString::number(index + 1) : QString()));
        row.index->setStyleSheet(QStringLiteral("color: %1;").arg(
            playing ? CTColors::accent().name() : CTColors::textSecondary().name()));
        if (row.like) {
            row.like->setVisible(app.isLiked(m_songs[index].id));
        }
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
