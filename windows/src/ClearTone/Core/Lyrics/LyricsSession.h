#pragma once

#include "Core/Async.h"
#include "Core/AsyncUtils.h"
#include "Core/Models/MusicModels.h"
#include "Core/Models/MusicProvider.h"

#include <functional>
#include <memory>
#include <optional>

namespace ct {

using LyricsProviderResolver = std::function<IMusicProvider*(const Song& song)>;

class LyricsSession {
public:
    explicit LyricsSession(LyricsProviderResolver resolve);

    std::function<void()> onChanged;

    const QList<LyricLine>& lines() const { return m_lines; }
    bool isLoading() const { return m_isLoading; }
    const std::optional<QString>& errorMessage() const { return m_errorMessage; }
    bool isPureMusic() const { return m_isPureMusic; }
    bool hasWordTiming() const { return m_hasWordTiming; }

    void reset();
    Task<void> loadAsync(const Song* song, CancellationToken ct = CancellationToken::none());

private:
    void notifyChanged();

    LyricsProviderResolver m_resolve;
    QList<LyricLine> m_lines;
    bool m_isLoading = false;
    std::optional<QString> m_errorMessage;
    bool m_isPureMusic = false;
    bool m_hasWordTiming = false;

    int m_token = 0;
    std::shared_ptr<LinkedCancellation> m_cts;
};

} // namespace ct
