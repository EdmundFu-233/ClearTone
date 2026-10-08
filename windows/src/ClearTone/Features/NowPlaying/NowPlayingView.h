#pragma once

#include "Core/Async.h"
#include "Core/Lyrics/LyricsSession.h"
#include "Core/Models/MusicModels.h"

#include <QDateTime>
#include <QHash>
#include <QList>
#include <QWidget>

#include <memory>
#include <optional>

class QLabel;
class QPushButton;
class QScrollArea;
class QSlider;
class QVBoxLayout;

namespace ct {

class AmbientBackground;
class CoverImage;

class NowPlayingView : public QWidget {
    Q_OBJECT

public:
    explicit NowPlayingView(QWidget* parent = nullptr);
    ~NowPlayingView() override;

protected:
    void showEvent(QShowEvent* event) override;
    void hideEvent(QHideEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;
    bool eventFilter(QObject* watched, QEvent* event) override;

private:
    struct LyricRow {
        QWidget* container = nullptr;
        QLabel* main = nullptr;
        QLabel* words = nullptr;
        QLabel* translation = nullptr;
        QLabel* romanization = nullptr;
    };

    void buildUi();
    QWidget* buildLeftColumn();
    QWidget* buildLyricHost();
    QWidget* buildLoadingPanel();
    QWidget* buildErrorPanel();
    QWidget* buildNoticePanel(const QString& text);

    void scheduleRender();
    void scheduleLyricsRender();
    void refresh();
    void refreshMuteGlyph();
    void refreshWordRow(int index, bool currentLine, int wordIndex);
    void loadLyrics();
    void renderLyrics();
    void renderLyricState();
    void updateCurrentLyric(double time);
    void updateWordProgress(double time);
    void updateRowCurrent(int index, bool current);
    void updateRowVisibility();
    void scrollToCurrent();
    void backToCurrent();
    void markUserScroll();
    void syncVolume();
    void showQualityMenu();
    void showRateMenu();
    void adjustOffset(double delta);
    void updateOffsetUi();
    void loadOffset();
    void saveOffset(double value);
    void handlePlayerTime(double time);
    Task<void> toggleLikeAsync(Song song);

    LyricsSession m_lyrics;

    AmbientBackground* m_background = nullptr;
    QWidget* m_root = nullptr;
    CoverImage* m_cover = nullptr;
    QLabel* m_titleText = nullptr;
    QPushButton* m_likeButton = nullptr;
    QPushButton* m_artistButton = nullptr;
    QLabel* m_sourceText = nullptr;
    QPushButton* m_modeButton = nullptr;
    QPushButton* m_previousButton = nullptr;
    QPushButton* m_playPauseButton = nullptr;
    QPushButton* m_nextButton = nullptr;
    QPushButton* m_muteButton = nullptr;
    QPushButton* m_qualityButton = nullptr;
    QPushButton* m_rateButton = nullptr;
    QPushButton* m_queueButton = nullptr;
    QSlider* m_progress = nullptr;
    QSlider* m_volume = nullptr;
    QLabel* m_currentTimeText = nullptr;
    QLabel* m_durationText = nullptr;
    QPushButton* m_closeButton = nullptr;

    QPushButton* m_translationToggle = nullptr;
    QPushButton* m_romanizationToggle = nullptr;
    QLabel* m_offsetText = nullptr;
    QPushButton* m_offsetDecrease = nullptr;
    QPushButton* m_offsetIncrease = nullptr;
    QPushButton* m_offsetReset = nullptr;
    QWidget* m_lyricHost = nullptr;
    QScrollArea* m_lyricScroll = nullptr;
    QWidget* m_lyricContainer = nullptr;
    QVBoxLayout* m_lyricContainerLayout = nullptr;
    QWidget* m_loadingPanel = nullptr;
    QWidget* m_errorPanel = nullptr;
    QWidget* m_purePanel = nullptr;
    QWidget* m_emptyPanel = nullptr;
    QLabel* m_lyricErrorText = nullptr;
    QPushButton* m_backToCurrentButton = nullptr;

    QList<LyricRow> m_rows;
    QHash<QWidget*, int> m_rowIndex;
    std::optional<Song> m_pendingSong;
    std::optional<QString> m_loadedLyricsSongID;
    std::optional<int> m_currentLineIndex;
    int m_lastWordIndex = -2;
    double m_lyricOffset = 0;
    QDateTime m_userScrollUntil;
    bool m_showTranslation = true;
    bool m_showRomanization = false;
    bool m_progressDragging = false;
    bool m_syncingProgress = false;
    bool m_syncingVolume = false;
    bool m_suppressScroll = false;
    bool m_renderScheduled = false;
    bool m_lyricsRenderScheduled = false;
    std::shared_ptr<CancellationTokenSource> m_lyricsCts;
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    int m_appObserver = 0;
    int m_songObserver = 0;
    int m_stateObserver = 0;
    int m_queueObserver = 0;
    int m_qualityObserver = 0;
    int m_durationObserver = 0;
    int m_volumeObserver = 0;
    int m_rateObserver = 0;
    int m_timeObserver = 0;
};

} // namespace ct
