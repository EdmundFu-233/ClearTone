#include "App/PlayerBarModel.h"

#include "App/AppState.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/L10n.h"
#include "Playback/PlayerController.h"

#include <algorithm>
#include <cmath>

namespace ct {

PlayerBarModel::PlayerBarModel()
    : m_player(&PlayerController::shared())
    , m_app(&AppState::shared())
{
}

PlayerController& PlayerBarModel::player() const { return *m_player; }

AppState& PlayerBarModel::app() const { return *m_app; }

QString PlayerBarModel::title() const
{
    const auto& song = m_player->currentSong();
    return song ? song->title : QStringLiteral("未在播放");
}

QString PlayerBarModel::artist() const
{
    const auto& song = m_player->currentSong();
    return song ? song->artistNames() : L10n::Common::AppName;
}

std::optional<QString> PlayerBarModel::coverUrl() const
{
    const auto& song = m_player->currentSong();
    if (!song) return std::nullopt;
    return song->coverURL;
}

QString PlayerBarModel::playPauseGlyph() const
{
    return m_player->playbackState().isPlayIntentActive() ? QStringLiteral("\uE769")
                                                          : QStringLiteral("\uE768");
}

QString PlayerBarModel::playPauseTooltip() const
{
    return m_player->playbackState().isPlayIntentActive() ? L10n::Common::Pause : L10n::Common::Play;
}

QString PlayerBarModel::modeGlyph() const
{
    switch (m_player->queue().mode) {
    case PlayMode::Sequential:
    case PlayMode::LoopAll:
        return QStringLiteral("\uE8EE");
    case PlayMode::LoopOne:
        return QStringLiteral("\uE8ED");
    default:
        return QStringLiteral("\uE8B1");
    }
}

QString PlayerBarModel::modeLabel() const { return playMode::displayName(m_player->queue().mode); }

QString PlayerBarModel::likeGlyph() const
{
    return isLiked() ? QStringLiteral("\uEB52") : QStringLiteral("\uEB51");
}

QColor PlayerBarModel::likeForeground() const
{
    return isLiked() ? CTColors::accent() : CTColors::textSecondary();
}

void PlayerBarModel::notifyLike()
{
    if (onChanged) onChanged();
}

void PlayerBarModel::refreshRate()
{
    if (onChanged) onChanged();
}

bool PlayerBarModel::isLiked() const
{
    const auto& song = m_player->currentSong();
    return song && m_app->isLiked(song->id);
}

double PlayerBarModel::progressPercent() const
{
    const double duration = m_player->duration();
    if (duration <= 0) return 0;
    return std::clamp(m_player->currentTime() / duration * 100.0, 0.0, 100.0);
}

QString PlayerBarModel::currentTimeText() const { return CTFormatting::time(m_player->currentTime()); }

QString PlayerBarModel::durationText() const { return CTFormatting::time(m_player->duration()); }

double PlayerBarModel::volumePercent() const
{
    return std::clamp(static_cast<double>(m_player->volume()) * 100.0, 0.0, 100.0);
}

bool PlayerBarModel::isMuted() const { return m_player->isMuted(); }

QString PlayerBarModel::qualityLabel() const
{
    const auto& song = m_player->currentSong();
    if (!song) return QString();
    return quality::displayName(m_player->effectiveQualityFor(song->id));
}

bool PlayerBarModel::isRateAdjusted() const { return m_player->isRateAdjusted(); }

QString PlayerBarModel::rateLabel() const { return m_player->playbackRateLabel(); }

std::optional<QString> PlayerBarModel::sourceText() const
{
    const auto source = m_player->playingSource();
    if (!source) return std::nullopt;
    return source->text;
}

void PlayerBarModel::refreshTime()
{
    if (onChanged) onChanged();
}

} // namespace ct
