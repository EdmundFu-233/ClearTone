#pragma once

#include <QColor>
#include <QString>

#include <functional>
#include <optional>

namespace ct {

class AppState;
class PlayerController;

// 播放栏派生显示（对应 C# App/PlayerBarModel.cs），纯逻辑、无 QObject。
class PlayerBarModel {
public:
    PlayerBarModel();

    // 对应 C# INotifyPropertyChanged；由持有方挂钩刷新界面。
    std::function<void()> onChanged;

    PlayerController& player() const;
    AppState& app() const;

    QString title() const;
    QString artist() const;
    std::optional<QString> coverUrl() const;
    QString playPauseGlyph() const;
    QString playPauseTooltip() const;
    QString modeGlyph() const;
    QString modeLabel() const;
    QString likeGlyph() const;
    QColor likeForeground() const;
    void notifyLike();
    void refreshRate();
    bool isLiked() const;
    double progressPercent() const;
    QString currentTimeText() const;
    QString durationText() const;
    double volumePercent() const;
    bool isMuted() const;
    QString qualityLabel() const;
    bool isRateAdjusted() const;
    QString rateLabel() const;
    std::optional<QString> sourceText() const;
    void refreshTime();

private:
    PlayerController* m_player;
    AppState* m_app;
};

} // namespace ct
