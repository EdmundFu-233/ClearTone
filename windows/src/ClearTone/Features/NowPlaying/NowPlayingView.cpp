#include "Features/NowPlaying/NowPlayingView.h"

#include "App/AppState.h"
#include "Core/Models/MusicProvider.h"
#include "Core/Persistence/AppSettings.h"
#include "Core/Persistence/PersistenceStore.h"
#include "DesignSystem/AmbientBackground.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "DesignSystem/L10n.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Playback/PlayerController.h"
#include "Playback/SongQuality.h"
#include "Providers/Netease/LRCParser.h"

#include <QAction>
#include <QFrame>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QMenu>
#include <QMouseEvent>
#include <QProgressBar>
#include <QPushButton>
#include <QScrollArea>
#include <QScrollBar>
#include <QSlider>
#include <QVBoxLayout>

#include <cmath>
#include <utility>

namespace ct {

namespace {

QColor primaryText() { return QColor(0xF4, 0xF4, 0xF6); }
QColor secondaryText() { return QColor(0xAE, 0xB3, 0xBF); }
QColor faintText() { return QColor(255, 255, 255, 0x73); }
QColor accentText() { return CTColors::DarkAccent; }

QString glyphStyle(const QColor& color, double size)
{
    return QStringLiteral("QPushButton { background: transparent; border: none; color: %1;"
                          " font-size: %2px; font-family: 'lucide'; }"
                          "QPushButton:hover { background: %3; border-radius: 6px; }")
        .arg(color.name())
        .arg(size)
        .arg(CTColors::DarkOverlay.name());
}

QPushButton* makeGlyphButton(const QString& glyph, const QColor& color, double size, QWidget* parent)
{
    auto* button = new QPushButton(glyph, parent);
    button->setFlat(true);
    button->setMinimumSize(32, 32);
    button->setCursor(Qt::PointingHandCursor);
    button->setStyleSheet(glyphStyle(color, size));
    return button;
}

QString sliderStyle()
{
    return QStringLiteral(
        "QSlider { background: transparent; }"
        "QSlider::groove:horizontal { height: 4px; background: %1; border-radius: 2px; }"
        "QSlider::sub-page:horizontal { background: %2; border-radius: 2px; }"
        "QSlider::handle:horizontal { width: 10px; margin: -4px 0; background: %2; border-radius: 5px; }")
        .arg(CTColors::DarkOverlay.name(), CTColors::DarkAccent.name());
}

QString modeGlyph(PlayMode mode)
{
    switch (mode) {
    case PlayMode::LoopOne:
        return QStringLiteral("\uE1FC");
    case PlayMode::Shuffle:
        return QStringLiteral("\uE161");
    default:
        return QStringLiteral("\uE149");
    }
}

QString wordRowHtml(const QList<LyricWord>& words, bool currentLine, int wordIndex)
{
    const int size = currentLine ? 20 : 16;
    const QString weight = currentLine ? QStringLiteral("600") : QStringLiteral("400");
    QString html = QStringLiteral("<div style='text-align:center;'>");
    for (int index = 0; index < words.size(); ++index) {
        QColor color = faintText();
        if (currentLine) {
            if (index < wordIndex) color = primaryText();
            else if (index == wordIndex) color = accentText();
        }
        html += QStringLiteral("<span style='font-size:%1px; font-weight:%2; color:%3;'>%4</span>")
                    .arg(size)
                    .arg(weight, color.name(), words.at(index).text.toHtmlEscaped());
    }
    html += QStringLiteral("</div>");
    return html;
}

} // namespace

NowPlayingView::NowPlayingView(QWidget* parent)
    : QWidget(parent)
    , m_lyrics([](const Song& song) -> IMusicProvider* {
        if (song.source != SongSource::Netease) return nullptr;
        return AppState::shared().provider();
    })
{
    setObjectName(QStringLiteral("ctNowPlayingView"));
    buildUi();

    m_lyrics.onChanged = [this, alive = m_alive] {
        if (!*alive) return;
        scheduleLyricsRender();
    };

    PlayerController& player = PlayerController::shared();
    m_songObserver = player.onSongChanged.subscribe([this, alive = m_alive] {
        if (!*alive) return;
        scheduleRender();
        if (isVisible()) {
            QMetaObject::invokeMethod(
                this,
                [this] {
                    if (isVisible()) loadLyrics();
                },
                Qt::QueuedConnection);
        }
    });
    m_stateObserver = player.onStateChanged.subscribe([this, alive = m_alive] {
        if (*alive) scheduleRender();
    });
    m_queueObserver = player.onQueueChanged.subscribe([this, alive = m_alive] {
        if (*alive) scheduleRender();
    });
    m_qualityObserver = player.onQualityChanged.subscribe([this, alive = m_alive] {
        if (*alive) scheduleRender();
    });
    m_durationObserver = player.onDurationChanged.subscribe([this, alive = m_alive] {
        if (*alive) scheduleRender();
    });
    m_volumeObserver = player.onVolumeChanged.subscribe([this, alive = m_alive] {
        if (*alive) scheduleRender();
    });
    m_rateObserver = player.onPlaybackRateChanged.subscribe([this, alive = m_alive] {
        if (*alive) scheduleRender();
    });
    m_timeObserver = player.timeUpdated.subscribe([this](double time) { handlePlayerTime(time); });
    m_appObserver = AppState::shared().changed.subscribe([this, alive = m_alive] {
        if (*alive) scheduleRender();
    });

    loadOffset();
    updateOffsetUi();
    refresh();
}

NowPlayingView::~NowPlayingView()
{
    *m_alive = false;
    if (m_lyricsCts) m_lyricsCts->cancel();
    PlayerController& player = PlayerController::shared();
    player.onSongChanged.unsubscribe(m_songObserver);
    player.onStateChanged.unsubscribe(m_stateObserver);
    player.onQueueChanged.unsubscribe(m_queueObserver);
    player.onQualityChanged.unsubscribe(m_qualityObserver);
    player.onDurationChanged.unsubscribe(m_durationObserver);
    player.onVolumeChanged.unsubscribe(m_volumeObserver);
    player.onPlaybackRateChanged.unsubscribe(m_rateObserver);
    player.timeUpdated.unsubscribe(m_timeObserver);
    AppState::shared().changed.unsubscribe(m_appObserver);
}

void NowPlayingView::buildUi()
{
    m_background = new AmbientBackground(this);

    auto* outer = new QVBoxLayout(this);
    outer->setContentsMargins(0, 0, 0, 0);
    outer->setSpacing(0);
    m_root = new QWidget(this);
    outer->addWidget(m_root);

    auto* grid = new QGridLayout(m_root);
    grid->setContentsMargins(0, 0, 0, 0);

    auto* content = new QWidget(m_root);
    auto* columns = new QHBoxLayout(content);
    columns->setContentsMargins(0, 0, 0, 0);
    columns->setSpacing(0);
    columns->addWidget(buildLeftColumn(), 1);

    auto* right = new QWidget(content);
    auto* rightLayout = new QVBoxLayout(right);
    rightLayout->setContentsMargins(0, CTSpacing::Lg, CTSpacing::Lg, CTSpacing::Lg);
    rightLayout->setSpacing(CTSpacing::Md);

    auto* toolbar = new QWidget(right);
    auto* toolbarLayout = new QHBoxLayout(toolbar);
    toolbarLayout->setContentsMargins(0, 0, 0, 0);
    toolbarLayout->setSpacing(CTSpacing::Sm);

    const QString toggleStyle = QStringLiteral(
        "QPushButton { background: transparent; color: %1; border: 1px solid %2; border-radius: 6px;"
        " padding: 3px 10px; font-size: 12px; }"
        "QPushButton:checked { background: %2; color: %3; }")
                                    .arg(secondaryText().name())
                                    .arg(CTColors::DarkOverlay.name())
                                    .arg(primaryText().name());
    m_translationToggle = new QPushButton(QStringLiteral("翻译"), toolbar);
    m_translationToggle->setCheckable(true);
    m_translationToggle->setChecked(true);
    m_translationToggle->setCursor(Qt::PointingHandCursor);
    m_translationToggle->setStyleSheet(toggleStyle);
    m_romanizationToggle = new QPushButton(QStringLiteral("音译"), toolbar);
    m_romanizationToggle->setCheckable(true);
    m_romanizationToggle->setCursor(Qt::PointingHandCursor);
    m_romanizationToggle->setStyleSheet(toggleStyle);
    toolbarLayout->addWidget(m_translationToggle);
    toolbarLayout->addWidget(m_romanizationToggle);
    toolbarLayout->addStretch(1);

    const QString smallButtonStyle = QStringLiteral(
        "QPushButton { background: transparent; border: none; color: %1; font-size: 12px;"
        " padding: 3px 8px; border-radius: 6px; }"
        "QPushButton:hover { background: %2; }"
        "QPushButton:disabled { color: %3; }")
                                         .arg(primaryText().name(), CTColors::DarkOverlay.name(),
                                             faintText().name());
    m_offsetDecrease = new QPushButton(QStringLiteral("-"), toolbar);
    m_offsetIncrease = new QPushButton(QStringLiteral("+"), toolbar);
    m_offsetReset = new QPushButton(QStringLiteral("重置"), toolbar);
    for (QPushButton* button : {m_offsetDecrease, m_offsetIncrease, m_offsetReset}) {
        button->setFlat(true);
        button->setCursor(Qt::PointingHandCursor);
        button->setStyleSheet(smallButtonStyle);
    }
    m_offsetText = new QLabel(QStringLiteral("0.0s"), toolbar);
    m_offsetText->setAlignment(Qt::AlignCenter);
    m_offsetText->setMinimumWidth(64);
    m_offsetText->setStyleSheet(QStringLiteral("color: %1; font-size: 12px;").arg(secondaryText().name()));
    toolbarLayout->addWidget(m_offsetDecrease);
    toolbarLayout->addWidget(m_offsetText);
    toolbarLayout->addWidget(m_offsetIncrease);
    toolbarLayout->addWidget(m_offsetReset);

    rightLayout->addWidget(toolbar);
    rightLayout->addWidget(buildLyricHost(), 1);
    columns->addWidget(right, 1);
    grid->addWidget(content, 0, 0);

    m_closeButton = makeGlyphButton(QStringLiteral("\uE1B1"), primaryText(), 14, m_root);
    m_closeButton->setToolTip(L10n::Common::Close);
    grid->addWidget(m_closeButton, 0, 0, Qt::AlignRight | Qt::AlignTop);

    connect(m_translationToggle, &QPushButton::toggled, this, [this](bool checked) {
        m_showTranslation = checked;
        updateRowVisibility();
    });
    connect(m_romanizationToggle, &QPushButton::toggled, this, [this](bool checked) {
        m_showRomanization = checked;
        updateRowVisibility();
    });
    connect(m_offsetDecrease, &QPushButton::clicked, this, [this] { adjustOffset(-0.1); });
    connect(m_offsetIncrease, &QPushButton::clicked, this, [this] { adjustOffset(0.1); });
    connect(m_offsetReset, &QPushButton::clicked, this, [this] { adjustOffset(-m_lyricOffset); });
    connect(m_closeButton, &QPushButton::clicked, this,
        [] { AppState::shared().setIsNowPlayingExpanded(false); });
}

QWidget* NowPlayingView::buildLeftColumn()
{
    auto* left = new QWidget();
    left->setMaximumWidth(460);
    auto* layout = new QVBoxLayout(left);
    layout->setContentsMargins(CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl, CTSpacing::Xl);
    layout->setSpacing(CTSpacing::Md);
    layout->addStretch(1);

    m_cover = new CoverImage(left);
    m_cover->setFixedSize(260, 260);
    m_cover->setCornerRadius(CTRadius::Large);
    layout->addWidget(m_cover, 0, Qt::AlignHCenter);

    auto* titleRow = new QWidget(left);
    auto* titleLayout = new QHBoxLayout(titleRow);
    titleLayout->setContentsMargins(0, 0, 0, 0);
    titleLayout->setSpacing(CTSpacing::Sm);
    m_titleText = new ui::ElidedLabel(QStringLiteral("未在播放"), titleRow);
    m_titleText->setStyleSheet(QStringLiteral("color: %1; font-size: 26px; font-weight: 600;")
                                   .arg(primaryText().name()));
    m_titleText->setMinimumWidth(120);
    m_titleText->setMaximumWidth(360);
    m_titleText->setAlignment(Qt::AlignCenter);
    titleLayout->addWidget(m_titleText, 1);
    m_likeButton = makeGlyphButton(QStringLiteral("\uE0F5"), secondaryText(), 20, titleRow);
    m_likeButton->setToolTip(QStringLiteral("收藏到喜欢的音乐"));
    titleLayout->addWidget(m_likeButton);
    layout->addWidget(titleRow);

    m_artistButton = new QPushButton(QStringLiteral("未知艺术家"), left);
    m_artistButton->setFlat(true);
    m_artistButton->setCursor(Qt::PointingHandCursor);
    m_artistButton->setToolTip(QStringLiteral("打开歌手"));
    m_artistButton->setStyleSheet(
        QStringLiteral("QPushButton { background: transparent; border: none; color: %1;"
                       " font-size: 16px; padding: 0; }")
            .arg(secondaryText().name()));
    layout->addWidget(m_artistButton, 0, Qt::AlignHCenter);

    m_sourceText = new QLabel(QString(), left);
    m_sourceText->setAlignment(Qt::AlignCenter);
    m_sourceText->setStyleSheet(QStringLiteral("color: %1; font-size: 12px;").arg(secondaryText().name()));
    layout->addWidget(m_sourceText, 0, Qt::AlignHCenter);

    auto* controls = new QWidget(left);
    auto* controlsLayout = new QHBoxLayout(controls);
    controlsLayout->setContentsMargins(0, 0, 0, 0);
    controlsLayout->setSpacing(CTSpacing::Lg);
    m_modeButton = makeGlyphButton(QStringLiteral("\uE149"), primaryText(), 16, controls);
    m_previousButton = makeGlyphButton(QStringLiteral("\uE162"), primaryText(), 18, controls);
    m_playPauseButton = makeGlyphButton(QStringLiteral("\uE13F"), accentText(), 36, controls);
    m_nextButton = makeGlyphButton(QStringLiteral("\uE163"), primaryText(), 18, controls);
    controlsLayout->addWidget(m_modeButton);
    controlsLayout->addWidget(m_previousButton);
    controlsLayout->addWidget(m_playPauseButton);
    controlsLayout->addWidget(m_nextButton);
    layout->addWidget(controls, 0, Qt::AlignHCenter);

    auto* progressRow = new QWidget(left);
    progressRow->setMaximumWidth(440);
    auto* progressLayout = new QHBoxLayout(progressRow);
    progressLayout->setContentsMargins(0, 0, 0, 0);
    progressLayout->setSpacing(0);
    m_currentTimeText = new QLabel(QStringLiteral("0:00"), progressRow);
    m_currentTimeText->setStyleSheet(
        QStringLiteral("color: %1; font-size: 12px;").arg(secondaryText().name()));
    m_durationText = new QLabel(QStringLiteral("0:00"), progressRow);
    m_durationText->setStyleSheet(
        QStringLiteral("color: %1; font-size: 12px;").arg(secondaryText().name()));
    m_progress = new QSlider(Qt::Horizontal, progressRow);
    m_progress->setRange(0, 100);
    m_progress->setStyleSheet(sliderStyle());
    progressLayout->addWidget(m_currentTimeText);
    progressLayout->addWidget(m_progress, 1);
    progressLayout->addWidget(m_durationText);
    layout->addWidget(progressRow);

    auto* volumeRow = new QWidget(left);
    auto* volumeLayout = new QHBoxLayout(volumeRow);
    volumeLayout->setContentsMargins(0, 0, 0, 0);
    volumeLayout->setSpacing(CTSpacing::Sm);
    m_muteButton = makeGlyphButton(QStringLiteral("\uE1AA"), primaryText(), 15, volumeRow);
    m_muteButton->setToolTip(QStringLiteral("静音"));
    m_volume = new QSlider(Qt::Horizontal, volumeRow);
    m_volume->setRange(0, 100);
    m_volume->setFixedWidth(130);
    m_volume->setStyleSheet(sliderStyle());
    m_qualityButton = new QPushButton(QStringLiteral("音质"), volumeRow);
    m_qualityButton->setFlat(true);
    m_qualityButton->setCursor(Qt::PointingHandCursor);
    m_qualityButton->setToolTip(QStringLiteral("为这首歌指定音质"));
    m_qualityButton->setStyleSheet(
        QStringLiteral("QPushButton { background: transparent; border: none; color: %1;"
                       " font-size: 12px; padding: 3px 8px; border-radius: 6px; }"
                       "QPushButton:hover { background: %2; }")
            .arg(primaryText().name(), CTColors::DarkOverlay.name()));
    m_rateButton = new QPushButton(QStringLiteral("1.0x"), volumeRow);
    m_rateButton->setFlat(true);
    m_rateButton->setCursor(Qt::PointingHandCursor);
    m_rateButton->setToolTip(QStringLiteral("播放速度"));
    m_rateButton->setStyleSheet(
        QStringLiteral("QPushButton { background: transparent; border: none; color: %1;"
                       " font-size: 12px; padding: 3px 8px; border-radius: 6px; }"
                       "QPushButton:hover { background: %2; }")
            .arg(accentText().name(), CTColors::DarkOverlay.name()));
    m_queueButton = makeGlyphButton(QStringLiteral("\uE2DF"), primaryText(), 15, volumeRow);
    m_queueButton->setToolTip(L10n::Common::Queue);
    volumeLayout->addStretch(1);
    volumeLayout->addWidget(m_muteButton);
    volumeLayout->addWidget(m_volume);
    volumeLayout->addWidget(m_rateButton);
    volumeLayout->addWidget(m_qualityButton);
    volumeLayout->addWidget(m_queueButton);
    volumeLayout->addStretch(1);
    layout->addWidget(volumeRow);
    layout->addStretch(1);

    connect(m_modeButton, &QPushButton::clicked, this, [] {
        PlayerController::shared().cyclePlayMode();
    });
    connect(m_previousButton, &QPushButton::clicked, this, [] {
        PlayerController::shared().previous();
    });
    connect(m_playPauseButton, &QPushButton::clicked, this, [] {
        PlayerController::shared().togglePlayPause();
    });
    connect(m_nextButton, &QPushButton::clicked, this, [] {
        PlayerController::shared().next();
    });
    connect(m_muteButton, &QPushButton::clicked, this, [this] {
        PlayerController& player = PlayerController::shared();
        player.setMuted(!player.isMuted());
        refreshMuteGlyph();
    });
    connect(m_qualityButton, &QPushButton::clicked, this, [this] { showQualityMenu(); });
    connect(m_rateButton, &QPushButton::clicked, this, [this] { showRateMenu(); });
    connect(m_queueButton, &QPushButton::clicked, this,
        [] { AppState::shared().setShowQueue(true); });
    connect(m_likeButton, &QPushButton::clicked, this, [this] {
        const std::optional<Song> song = PlayerController::shared().currentSong();
        if (!song.has_value()) return;
        detach(toggleLikeAsync(*song));
    });
    connect(m_artistButton, &QPushButton::clicked, this, [] {
        const std::optional<Song> song = PlayerController::shared().currentSong();
        if (!song.has_value() || song->artists.isEmpty()) return;
        AppState::shared().openArtist(song->artists.first().id);
        AppState::shared().setIsNowPlayingExpanded(false);
    });
    connect(m_progress, &QSlider::sliderPressed, this, [this] { m_progressDragging = true; });
    connect(m_progress, &QSlider::sliderReleased, this, [this] {
        if (!m_progressDragging) return;
        m_progressDragging = false;
        PlayerController& player = PlayerController::shared();
        if (player.duration() > 0) {
            player.commitSeek(m_progress->value() / 100.0 * player.duration());
        }
    });
    connect(m_progress, &QSlider::valueChanged, this, [this](int value) {
        if (!m_progressDragging || m_syncingProgress) return;
        PlayerController& player = PlayerController::shared();
        if (player.duration() > 0) {
            player.previewSeek(value / 100.0 * player.duration());
        }
    });
    connect(m_volume, &QSlider::valueChanged, this, [this](int value) {
        if (m_syncingVolume) return;
        PlayerController& player = PlayerController::shared();
        player.setVolume(static_cast<float>(value / 100.0));
        if (player.volume() > 0.001f) player.setMuted(false);
        refreshMuteGlyph();
    });

    return left;
}

QWidget* NowPlayingView::buildLyricHost()
{
    m_lyricHost = new QWidget();
    auto* grid = new QGridLayout(m_lyricHost);
    grid->setContentsMargins(0, 0, 0, CTSpacing::Md);

    m_lyricContainer = new QWidget();
    m_lyricContainerLayout = new QVBoxLayout(m_lyricContainer);
    m_lyricContainerLayout->setContentsMargins(CTSpacing::Sm, 0, CTSpacing::Md, 0);
    m_lyricContainerLayout->setSpacing(CTSpacing::Md);

    m_lyricScroll = new QScrollArea(m_lyricHost);
    m_lyricScroll->setWidgetResizable(true);
    m_lyricScroll->setFrameShape(QFrame::NoFrame);
    m_lyricScroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    m_lyricScroll->setStyleSheet(QStringLiteral(
        "QScrollArea { background: transparent; border: none; }"
        "QScrollArea > QWidget > QWidget { background: transparent; }"));
    m_lyricScroll->setWidget(m_lyricContainer);
    grid->addWidget(m_lyricScroll, 0, 0);

    m_loadingPanel = buildLoadingPanel();
    grid->addWidget(m_loadingPanel, 0, 0, Qt::AlignCenter);
    m_errorPanel = buildErrorPanel();
    grid->addWidget(m_errorPanel, 0, 0, Qt::AlignCenter);
    m_purePanel = buildNoticePanel(L10n::Player::PureMusic);
    grid->addWidget(m_purePanel, 0, 0, Qt::AlignCenter);
    m_emptyPanel = buildNoticePanel(L10n::Player::NoLyrics);
    grid->addWidget(m_emptyPanel, 0, 0, Qt::AlignCenter);

    m_backToCurrentButton = ui::accentButton(L10n::Player::BackToCurrent);
    m_backToCurrentButton->setStyleSheet(
        QStringLiteral("QPushButton { background: %1; color: white; border: none;"
                       " border-radius: 6px; padding: 4px 12px; font-size: 12px; }")
            .arg(CTColors::DarkAccent.name()));
    m_backToCurrentButton->setVisible(false);
    grid->addWidget(m_backToCurrentButton, 0, 0, Qt::AlignHCenter | Qt::AlignBottom);

    m_loadingPanel->setVisible(false);
    m_errorPanel->setVisible(false);
    m_purePanel->setVisible(false);
    m_emptyPanel->setVisible(false);

    connect(m_backToCurrentButton, &QPushButton::clicked, this, [this] { backToCurrent(); });
    connect(m_lyricScroll->verticalScrollBar(), &QScrollBar::valueChanged, this, [this] {
        if (m_suppressScroll) return;
        markUserScroll();
    });
    m_lyricScroll->viewport()->installEventFilter(this);
    return m_lyricHost;
}

QWidget* NowPlayingView::buildLoadingPanel()
{
    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Md);
    layout->setAlignment(Qt::AlignCenter);
    auto* progress = new QProgressBar(panel);
    progress->setRange(0, 0);
    progress->setTextVisible(false);
    progress->setFixedWidth(160);
    layout->addWidget(progress, 0, Qt::AlignHCenter);
    auto* label = new QLabel(L10n::Player::LoadingLyrics, panel);
    label->setStyleSheet(QStringLiteral("color: %1;").arg(secondaryText().name()));
    layout->addWidget(label, 0, Qt::AlignHCenter);
    return panel;
}

QWidget* NowPlayingView::buildErrorPanel()
{
    auto* panel = new QWidget();
    auto* layout = new QVBoxLayout(panel);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(CTSpacing::Sm);
    layout->setAlignment(Qt::AlignCenter);
    m_lyricErrorText = new QLabel(panel);
    m_lyricErrorText->setWordWrap(true);
    m_lyricErrorText->setAlignment(Qt::AlignCenter);
    m_lyricErrorText->setMaximumWidth(420);
    m_lyricErrorText->setStyleSheet(QStringLiteral("color: %1;").arg(secondaryText().name()));
    layout->addWidget(m_lyricErrorText, 0, Qt::AlignHCenter);
    auto* retry = ui::accentButton(L10n::Common::Retry);
    connect(retry, &QPushButton::clicked, this, [this] { loadLyrics(); });
    layout->addWidget(retry, 0, Qt::AlignHCenter);
    return panel;
}

QWidget* NowPlayingView::buildNoticePanel(const QString& text)
{
    auto* label = new QLabel(text);
    label->setAlignment(Qt::AlignCenter);
    label->setStyleSheet(
        QStringLiteral("color: %1; font-size: 18px;").arg(secondaryText().name()));
    return label;
}

void NowPlayingView::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    m_background->setGeometry(rect());
    m_background->reloadAnimationPolicy();
    m_background->lower();
    loadOffset();
    updateOffsetUi();
    refresh();

    const std::optional<Song> song = PlayerController::shared().currentSong();
    const QString currentID = song.has_value() ? song->id : QString();
    const bool missing = !m_loadedLyricsSongID.has_value() || *m_loadedLyricsSongID != currentID;
    const bool blank = !m_lyrics.isLoading() && !m_lyrics.errorMessage().has_value()
        && !m_lyrics.isPureMusic() && m_lyrics.lines().isEmpty();
    if (missing || blank) loadLyrics();
}

void NowPlayingView::hideEvent(QHideEvent* event)
{
    QWidget::hideEvent(event);
    if (m_lyricsCts) m_lyricsCts->cancel();
    m_lyricsCts = nullptr;
}

void NowPlayingView::resizeEvent(QResizeEvent* event)
{
    QWidget::resizeEvent(event);
    if (m_background != nullptr) m_background->setGeometry(rect());
    if (m_cover != nullptr) {
        const int side = qBound(160, qMin(height() - 275, width() / 2 - 80), 320);
        m_cover->setFixedSize(side, side);
    }
    if (m_root != nullptr) m_root->raise();
}

bool NowPlayingView::eventFilter(QObject* watched, QEvent* event)
{
    if (event->type() == QEvent::MouseButtonPress) {
        auto* widget = qobject_cast<QWidget*>(watched);
        const auto found = m_rowIndex.constFind(widget);
        if (found != m_rowIndex.constEnd()) {
            auto* mouseEvent = static_cast<QMouseEvent*>(event);
            if (mouseEvent->button() == Qt::LeftButton) {
                const int index = *found;
                if (index >= 0 && index < m_lyrics.lines().size()) {
                    PlayerController::shared().commitSeek(
                        qMax(0.0, m_lyrics.lines().at(index).time - m_lyricOffset));
                }
                return true;
            }
        }
    }
    if (watched == m_lyricScroll->viewport() && event->type() == QEvent::Wheel) {
        markUserScroll();
    }
    return QWidget::eventFilter(watched, event);
}

void NowPlayingView::scheduleRender()
{
    if (m_renderScheduled) return;
    m_renderScheduled = true;
    QMetaObject::invokeMethod(
        this,
        [this] {
            m_renderScheduled = false;
            refresh();
        },
        Qt::QueuedConnection);
}

void NowPlayingView::scheduleLyricsRender()
{
    if (m_lyricsRenderScheduled) return;
    m_lyricsRenderScheduled = true;
    QMetaObject::invokeMethod(
        this,
        [this] {
            m_lyricsRenderScheduled = false;
            renderLyrics();
            renderLyricState();
        },
        Qt::QueuedConnection);
}

void NowPlayingView::refresh()
{
    if (!*m_alive) return;
    PlayerController& player = PlayerController::shared();
    const std::optional<Song> song = player.currentSong();

    m_titleText->setFullText(song.has_value() ? song->title : QStringLiteral("未在播放"));
    const bool hasArtist = song.has_value() && !song->artists.isEmpty();
    const QString artistText = hasArtist ? song->artistNames() : QStringLiteral("未知艺术家");
    m_artistButton->setText(m_artistButton->fontMetrics().elidedText(artistText, Qt::ElideRight, 380));
    m_artistButton->setToolTip(artistText);
    m_artistButton->setEnabled(hasArtist);
    m_cover->setCoverURL(song.has_value() ? song->coverURL : std::nullopt, 600);

    const std::optional<PlayingSourceInfo> source = player.playingSource();
    m_sourceText->setText(source.has_value() ? source->text : QString());
    m_sourceText->setVisible(!m_sourceText->text().isEmpty());
    m_sourceText->setToolTip(source.has_value() ? source->detail : QString());

    m_playPauseButton->setText(player.playbackState().isPlayIntentActive() ? QStringLiteral("\uE131")
                                                                           : QStringLiteral("\uE13F"));
    m_modeButton->setText(modeGlyph(player.queue().mode));
    m_modeButton->setToolTip(playMode::displayName(player.queue().mode));

    const bool isNetease = song.has_value() && song->source == SongSource::Netease;
    const bool liked = song.has_value() && AppState::shared().isLiked(song->id);
    m_likeButton->setText(liked ? QStringLiteral("\uE0F5") : QStringLiteral("\uE0F5"));
    m_likeButton->setStyleSheet(glyphStyle(liked ? accentText() : secondaryText(), 20));
    m_likeButton->setEnabled(isNetease && AppState::shared().isLoggedIn());
    m_likeButton->setToolTip(liked ? QStringLiteral("取消收藏")
                                   : QStringLiteral("收藏到喜欢的音乐"));

    const std::optional<QualityLevel> overrideLevel
        = song.has_value() ? player.qualityOverrideFor(song->id) : std::nullopt;
    m_qualityButton->setText(overrideLevel.has_value() ? quality::displayName(*overrideLevel)
                                                       : QStringLiteral("音质"));
    m_qualityButton->setVisible(isNetease);
    m_qualityButton->setEnabled(isNetease);
    m_rateButton->setText(player.playbackRateLabel());

    m_durationText->setText(CTFormatting::time(player.duration()));
    m_currentTimeText->setText(CTFormatting::time(player.currentTime()));
    syncVolume();
    refreshMuteGlyph();

    if (!m_progressDragging) {
        m_syncingProgress = true;
        const double percent = player.duration() > 0
            ? qBound(0.0, player.currentTime() / player.duration() * 100, 100.0)
            : 0.0;
        m_progress->setValue(static_cast<int>(std::lround(percent)));
        m_syncingProgress = false;
    }
    updateCurrentLyric(player.currentTime());
}

void NowPlayingView::syncVolume()
{
    m_syncingVolume = true;
    m_volume->setValue(
        static_cast<int>(std::lround(qBound(0.0, PlayerController::shared().volume() * 100, 100.0))));
    m_syncingVolume = false;
}

void NowPlayingView::refreshMuteGlyph()
{
    PlayerController& player = PlayerController::shared();
    m_muteButton->setText(player.isMuted() || player.volume() <= 0.001f ? QStringLiteral("\uE1AB")
                                                                        : QStringLiteral("\uE1AA"));
}

void NowPlayingView::handlePlayerTime(double time)
{
    if (!*m_alive) return;
    PlayerController& player = PlayerController::shared();
    m_currentTimeText->setText(CTFormatting::time(time));
    m_durationText->setText(CTFormatting::time(player.duration()));
    if (!m_progressDragging) {
        m_syncingProgress = true;
        const double percent = player.duration() > 0
            ? qBound(0.0, time / player.duration() * 100, 100.0)
            : 0.0;
        m_progress->setValue(static_cast<int>(std::lround(percent)));
        m_syncingProgress = false;
    }
    updateCurrentLyric(time);
    updateWordProgress(time);
}

void NowPlayingView::showQualityMenu()
{
    PlayerController& player = PlayerController::shared();
    const std::optional<Song> song = player.currentSong();
    if (!song.has_value() || song->source != SongSource::Netease) return;
    const std::optional<QualityLevel> current = player.qualityOverrideFor(song->id);

    auto* menu = new QMenu(this);
    menu->setAttribute(Qt::WA_DeleteOnClose);
    auto* autoAction = menu->addAction(QStringLiteral("自动（跟随全局设置）"));
    autoAction->setCheckable(true);
    autoAction->setChecked(!current.has_value());
    const QString songID = song->id;
    connect(autoAction, &QAction::triggered, this, [this, songID] {
        PlayerController::shared().setQualityOverride(std::nullopt, songID);
        refresh();
    });
    for (const QualityLevel level : songQualityPolicy::selectableLevels) {
        auto* action = menu->addAction(quality::displayName(level));
        action->setCheckable(true);
        action->setChecked(current.has_value() && *current == level);
        connect(action, &QAction::triggered, this, [this, songID, level] {
            PlayerController::shared().setQualityOverride(level, songID);
            refresh();
        });
    }
    menu->popup(m_qualityButton->mapToGlobal(QPoint(0, m_qualityButton->height())));
}

void NowPlayingView::showRateMenu()
{
    auto* menu = new QMenu(this);
    menu->setAttribute(Qt::WA_DeleteOnClose);
    PlayerController& player = PlayerController::shared();
    for (const float rate : PlayerController::availableRates()) {
        QAction* action = menu->addAction(PlayerController::rateLabel(rate));
        action->setCheckable(true);
        action->setChecked(std::abs(player.playbackRate() - rate) < 0.001f);
        connect(action, &QAction::triggered, this, [this, rate] {
            PlayerController::shared().setPlaybackRate(rate);
            refresh();
        });
    }
    menu->popup(m_rateButton->mapToGlobal(QPoint(0, -menu->sizeHint().height())));
}

void NowPlayingView::loadLyrics()
{
    if (m_lyricsCts) m_lyricsCts->cancel();
    m_lyricsCts = std::make_shared<CancellationTokenSource>();
    m_pendingSong = PlayerController::shared().currentSong();
    m_loadedLyricsSongID = m_pendingSong.has_value() ? std::optional<QString>(m_pendingSong->id)
                                                     : std::nullopt;
    const auto previous = m_currentLineIndex;
    if (previous.has_value() && *previous >= 0 && *previous < m_rows.size()) {
        updateRowCurrent(*previous, false);
    }
    m_currentLineIndex.reset();
    m_lastWordIndex = -2;
    detach(m_lyrics.loadAsync(m_pendingSong.has_value() ? &*m_pendingSong : nullptr,
        m_lyricsCts->token()));
}

void NowPlayingView::renderLyrics()
{
    if (!*m_alive) return;
    while (QLayoutItem* item = m_lyricContainerLayout->takeAt(0)) {
        if (QWidget* widget = item->widget()) widget->deleteLater();
        delete item;
    }
    m_rows.clear();
    m_rowIndex.clear();
    m_currentLineIndex.reset();
    m_lastWordIndex = -2;

    const QList<LyricLine>& lines = m_lyrics.lines();
    for (int index = 0; index < lines.size(); ++index) {
        const LyricLine& line = lines.at(index);
        LyricRow row;
        row.container = new QWidget(m_lyricContainer);
        row.container->setCursor(Qt::PointingHandCursor);
        auto* layout = new QVBoxLayout(row.container);
        layout->setContentsMargins(CTSpacing::Sm, CTSpacing::Xs, CTSpacing::Sm, CTSpacing::Xs);
        layout->setSpacing(2);
        layout->setAlignment(Qt::AlignHCenter);

        row.main = new QLabel(line.text.isEmpty() ? QStringLiteral("♪") : line.text, row.container);
        row.main->setWordWrap(true);
        row.main->setAlignment(Qt::AlignCenter);
        row.main->setMaximumWidth(560);
        row.main->setStyleSheet(QStringLiteral("color: %1; font-size: 16px;").arg(faintText().name()));
        layout->addWidget(row.main, 0, Qt::AlignHCenter);

        if (line.words.has_value() && !line.words->isEmpty()) {
            row.main->setVisible(false);
            row.words = new QLabel(row.container);
            row.words->setTextFormat(Qt::RichText);
            row.words->setWordWrap(true);
            row.words->setAlignment(Qt::AlignCenter);
            row.words->setMaximumWidth(560);
            row.words->setText(wordRowHtml(*line.words, false, -1));
            layout->addWidget(row.words, 0, Qt::AlignHCenter);
        }

        row.translation = new QLabel(line.translation.value_or(QString()), row.container);
        row.translation->setWordWrap(true);
        row.translation->setAlignment(Qt::AlignCenter);
        row.translation->setMaximumWidth(560);
        row.translation->setStyleSheet(
            QStringLiteral("color: %1; font-size: 14px;").arg(faintText().name()));
        row.translation->setVisible(m_showTranslation && line.translation.has_value()
            && !line.translation->isEmpty());
        layout->addWidget(row.translation, 0, Qt::AlignHCenter);

        row.romanization = new QLabel(line.romanization.value_or(QString()), row.container);
        row.romanization->setWordWrap(true);
        row.romanization->setAlignment(Qt::AlignCenter);
        row.romanization->setMaximumWidth(560);
        row.romanization->setStyleSheet(
            QStringLiteral("color: %1; font-size: 14px;").arg(faintText().name()));
        row.romanization->setVisible(m_showRomanization && line.romanization.has_value()
            && !line.romanization->isEmpty());
        layout->addWidget(row.romanization, 0, Qt::AlignHCenter);

        m_lyricContainerLayout->addWidget(row.container);
        m_rowIndex.insert(row.container, index);
        row.container->installEventFilter(this);
        m_rows.append(row);
    }
    m_lyricContainerLayout->addStretch(1);

    if (!m_rows.isEmpty()) {
        updateCurrentLyric(PlayerController::shared().currentTime());
    } else {
        m_backToCurrentButton->setVisible(false);
    }
}

void NowPlayingView::renderLyricState()
{
    if (!*m_alive) return;
    const bool loading = m_lyrics.isLoading();
    const bool hasError = m_lyrics.errorMessage().has_value();
    const bool pure = m_lyrics.isPureMusic();
    const bool hasLines = !m_lyrics.lines().isEmpty();

    m_loadingPanel->setVisible(loading);
    m_errorPanel->setVisible(!loading && hasError);
    m_purePanel->setVisible(!loading && !hasError && pure);
    m_emptyPanel->setVisible(!loading && !hasError && !pure && !hasLines);
    m_lyricScroll->setVisible(!loading && !hasError && !pure && hasLines);
    if (hasError) m_lyricErrorText->setText(*m_lyrics.errorMessage());
    if (!m_lyricScroll->isVisible() && !hasLines) m_backToCurrentButton->setVisible(false);
}

void NowPlayingView::updateCurrentLyric(double time)
{
    if (m_rows.isEmpty()) return;
    const std::optional<int> index = LRCParser::currentLineIndex(m_lyrics.lines(), time, m_lyricOffset);
    if (index == m_currentLineIndex) return;
    const std::optional<int> previous = m_currentLineIndex;
    m_currentLineIndex = index;

    if (previous.has_value() && *previous >= 0 && *previous < m_rows.size()) {
        updateRowCurrent(*previous, false);
    }
    if (index.has_value() && *index >= 0 && *index < m_rows.size()) {
        updateRowCurrent(*index, true);
        m_lastWordIndex = -2;
        updateWordProgress(time);
        const int current = *index;
        QMetaObject::invokeMethod(
            this,
            [this, current] {
                if (!*m_alive || m_currentLineIndex != current) return;
                if (QDateTime::currentDateTime() >= m_userScrollUntil) {
                    m_backToCurrentButton->setVisible(false);
                    scrollToCurrent();
                } else {
                    m_backToCurrentButton->setVisible(true);
                }
            },
            Qt::QueuedConnection);
    } else {
        m_backToCurrentButton->setVisible(false);
    }
}

void NowPlayingView::updateWordProgress(double time)
{
    if (!m_currentLineIndex.has_value()) return;
    const int index = *m_currentLineIndex;
    if (index < 0 || index >= m_lyrics.lines().size() || index >= m_rows.size()) return;
    const LyricLine& line = m_lyrics.lines().at(index);
    if (!line.words.has_value() || line.words->isEmpty()) return;

    const double adjusted = time + m_lyricOffset;
    int wordIndex = -1;
    for (int i = 0; i < line.words->size(); ++i) {
        if (adjusted >= line.words->at(i).time) wordIndex = i;
        else break;
    }
    if (wordIndex == m_lastWordIndex) return;
    m_lastWordIndex = wordIndex;
    refreshWordRow(index, true, wordIndex);
}

void NowPlayingView::refreshWordRow(int index, bool currentLine, int wordIndex)
{
    if (index < 0 || index >= m_rows.size() || index >= m_lyrics.lines().size()) return;
    const LyricRow& row = m_rows.at(index);
    if (row.words == nullptr) return;
    const LyricLine& line = m_lyrics.lines().at(index);
    if (!line.words.has_value() || line.words->isEmpty()) return;
    row.words->setText(wordRowHtml(*line.words, currentLine, currentLine ? wordIndex : -1));
}

void NowPlayingView::updateRowCurrent(int index, bool current)
{
    if (index < 0 || index >= m_rows.size() || index >= m_lyrics.lines().size()) return;
    LyricRow& row = m_rows[index];
    if (row.words != nullptr) {
        refreshWordRow(index, current, -1);
    } else if (row.main != nullptr) {
        QFont font = row.main->font();
        font.setPixelSize(current ? 20 : 16);
        font.setBold(current);
        row.main->setFont(font);
        row.main->setStyleSheet(QStringLiteral("color: %1;").arg(
            current ? primaryText().name() : faintText().name()));
    }
    if (row.translation != nullptr) {
        row.translation->setStyleSheet(QStringLiteral("color: %1; font-size: 14px;").arg(
            current ? primaryText().name() : faintText().name()));
    }
    if (row.romanization != nullptr) {
        row.romanization->setStyleSheet(QStringLiteral("color: %1; font-size: 14px;").arg(
            current ? primaryText().name() : faintText().name()));
    }
}

void NowPlayingView::updateRowVisibility()
{
    for (const LyricRow& row : std::as_const(m_rows)) {
        if (row.translation != nullptr) {
            row.translation->setVisible(m_showTranslation && !row.translation->text().isEmpty());
        }
        if (row.romanization != nullptr) {
            row.romanization->setVisible(m_showRomanization && !row.romanization->text().isEmpty());
        }
    }
}

void NowPlayingView::scrollToCurrent()
{
    if (!m_currentLineIndex.has_value()) return;
    const int index = *m_currentLineIndex;
    if (index < 0 || index >= m_rows.size()) return;
    m_lyricContainer->layout()->activate();
    QWidget* container = m_rows.at(index).container;
    const int target = container->y() + container->height() / 2
        - m_lyricScroll->viewport()->height() / 2;
    m_suppressScroll = true;
    m_lyricScroll->verticalScrollBar()->setValue(
        qBound(0, target, m_lyricScroll->verticalScrollBar()->maximum()));
    m_suppressScroll = false;
}

void NowPlayingView::backToCurrent()
{
    m_userScrollUntil = QDateTime();
    m_backToCurrentButton->setVisible(false);
    scrollToCurrent();
}

void NowPlayingView::markUserScroll()
{
    m_userScrollUntil = QDateTime::currentDateTime().addSecs(6);
    m_backToCurrentButton->setVisible(m_currentLineIndex.has_value());
}

void NowPlayingView::adjustOffset(double delta)
{
    double next = qBound(-5.0, m_lyricOffset + delta, 5.0);
    next = std::round(next * 10) / 10;
    if (std::abs(next - m_lyricOffset) < 0.0001) return;
    const std::optional<int> previous = m_currentLineIndex;
    if (previous.has_value() && *previous >= 0 && *previous < m_rows.size()) {
        updateRowCurrent(*previous, false);
    }
    m_lyricOffset = next;
    saveOffset(m_lyricOffset);
    updateOffsetUi();
    m_currentLineIndex.reset();
    m_lastWordIndex = -2;
    updateCurrentLyric(PlayerController::shared().currentTime());
}

void NowPlayingView::updateOffsetUi()
{
    const bool adjusted = std::abs(m_lyricOffset) >= 0.001;
    if (!adjusted) {
        m_offsetText->setText(QStringLiteral("0.0s"));
    } else if (m_lyricOffset > 0) {
        m_offsetText->setText(QStringLiteral("提前 %1s").arg(m_lyricOffset, 0, 'f', 1));
    } else {
        m_offsetText->setText(QStringLiteral("延后 %1s").arg(-m_lyricOffset, 0, 'f', 1));
    }
    m_offsetText->setStyleSheet(QStringLiteral("color: %1; font-size: 12px;")
                                    .arg(adjusted ? accentText().name() : secondaryText().name()));
    m_offsetReset->setVisible(adjusted);
    m_offsetDecrease->setEnabled(m_lyricOffset > -5.0 + 0.0001);
    m_offsetIncrease->setEnabled(m_lyricOffset < 5.0 - 0.0001);
}

Task<void> NowPlayingView::toggleLikeAsync(Song song)
{
    auto alive = m_alive;
    try {
        co_await AppState::shared().toggleLike(song);
    } catch (const MusicException&) {
    } catch (const std::exception&) {
    }
    if (!*alive) co_return;
    scheduleRender();
}

void NowPlayingView::loadOffset()
{
    const QJsonValue stored = PersistenceStore::shared().loadSetting(QStringLiteral("appSettings"));
    const AppSettings settings =
        stored.isObject() ? AppSettings::fromJson(stored.toObject()) : AppSettings();
    m_lyricOffset = settings.lyricOffset;
}

void NowPlayingView::saveOffset(double value)
{
    const QJsonValue stored = PersistenceStore::shared().loadSetting(QStringLiteral("appSettings"));
    AppSettings settings = stored.isObject() ? AppSettings::fromJson(stored.toObject()) : AppSettings();
    settings.lyricOffset = value;
    PersistenceStore::shared().saveSetting(QStringLiteral("appSettings"), settings.toJson());
}

CT_REGISTER_OVERLAY(OverlayKind::NowPlaying, NowPlayingView);

} // namespace ct
