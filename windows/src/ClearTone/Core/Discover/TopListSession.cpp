#include "Core/Discover/TopListSession.h"

#include "Core/Logging/CTLog.h"
#include "Core/Models/MusicSocialProvider.h"

#include <utility>

namespace ct {

namespace {

QString unknownUserMessage(const std::exception& error)
{
    return MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
}

} // namespace

TopListSession::TopListSession(IMusicSocialProvider* source) : m_source(source) {}

Task<void> TopListSession::loadAsync(CancellationToken ct)
{
    m_token++;
    const int token = m_token;
    if (m_cts) m_cts->cancel();
    m_cts = std::make_shared<LinkedCancellation>(ct, CancellationToken::none());
    const CancellationToken pageToken = m_cts->token();
    m_isLoading = m_lists.isEmpty();
    m_errorMessage.reset();
    notifyChanged();
    if (m_source != nullptr) {
        try {
            QList<TopList> loaded = co_await m_source->fetchTopLists(pageToken);
            if (token == m_token && !pageToken.isCancellationRequested()) {
                m_lists = std::move(loaded);
                notifyChanged();
            }
        } catch (const MusicException& error) {
            if (!error.isCancelled() && token == m_token && !pageToken.isCancellationRequested()) {
                m_errorMessage = error.userFacingMessage();
                notifyChanged();
                CTLog::general().error(
                    QStringLiteral("加载榜单目录失败: %1").arg(CTLog::sanitize(error.message())));
            }
        } catch (const std::exception& error) {
            if (token == m_token && !pageToken.isCancellationRequested()) {
                m_errorMessage = unknownUserMessage(error);
                notifyChanged();
                CTLog::general().error(QStringLiteral("加载榜单目录失败: %1")
                                           .arg(CTLog::sanitize(QString::fromUtf8(error.what()))));
            }
        }
    }
    if (token == m_token) {
        m_isLoading = false;
        notifyChanged();
    }
}

void TopListSession::notifyChanged()
{
    if (onChanged) onChanged();
}

} // namespace ct
