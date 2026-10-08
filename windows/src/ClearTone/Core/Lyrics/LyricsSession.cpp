#include "Core/Lyrics/LyricsSession.h"

#include <utility>

namespace ct {

namespace {

QString unknownUserMessage(const std::exception& error)
{
    return MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
}

} // namespace

LyricsSession::LyricsSession(LyricsProviderResolver resolve) : m_resolve(std::move(resolve)) {}

void LyricsSession::reset()
{
    m_token++;
    if (m_cts) m_cts->cancel();
    m_cts = nullptr;
    m_lines.clear();
    m_isLoading = false;
    m_errorMessage.reset();
    m_isPureMusic = false;
    m_hasWordTiming = false;
    notifyChanged();
}

Task<void> LyricsSession::loadAsync(const Song* song, CancellationToken ct)
{
    if (ct.isCancellationRequested()) co_return;
    reset();

    IMusicProvider* provider = song == nullptr ? nullptr : m_resolve(*song);
    if (song == nullptr || provider == nullptr) co_return;

    const int token = m_token;
    m_cts = std::make_shared<LinkedCancellation>(ct, CancellationToken::none());
    const CancellationToken pageToken = m_cts->token();
    m_isLoading = true;
    notifyChanged();

    try {
        LyricResult result = co_await provider->fetchLyrics(song->id, pageToken);
        if (token == m_token && !pageToken.isCancellationRequested()) {
            m_lines = std::move(result.lines);
            m_isPureMusic = result.isPureMusic;
            m_hasWordTiming = result.hasWordTiming;
            notifyChanged();
        }
    } catch (const MusicException& error) {
        if (!error.isCancelled() && token == m_token && !pageToken.isCancellationRequested()) {
            m_errorMessage = error.userFacingMessage();
            notifyChanged();
        }
    } catch (const std::exception& error) {
        if (token == m_token && !pageToken.isCancellationRequested()) {
            m_errorMessage = unknownUserMessage(error);
            notifyChanged();
        }
    }
    if (token == m_token) {
        m_isLoading = false;
        notifyChanged();
    }
}

void LyricsSession::notifyChanged()
{
    if (onChanged) onChanged();
}

} // namespace ct
