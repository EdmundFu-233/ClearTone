#include "Core/Models/MusicError.h"

#include "Core/Logging/CTLog.h"

namespace ct {

namespace {

QString buildMessage(MusicErrorKind kind, const QString& detail, int code)
{
    switch (kind) {
    case MusicErrorKind::NotLoggedIn:
        return QStringLiteral("尚未登录，请先登录网易云账号");
    case MusicErrorKind::SessionExpired:
        return QStringLiteral("登录状态已过期，请重新登录");
    case MusicErrorKind::NetworkUnavailable:
        return QStringLiteral("网络不可用，请检查网络连接");
    case MusicErrorKind::RateLimited:
        return QStringLiteral("请求过于频繁，请稍后再试");
    case MusicErrorKind::SongUnavailable:
        return QStringLiteral("歌曲不可用：%1").arg(detail);
    case MusicErrorKind::NoPlayableURL:
        return QStringLiteral("无法获取播放地址，可能没有播放权限");
    case MusicErrorKind::ApiError:
        return QStringLiteral("接口错误 (%1)：%2").arg(code).arg(detail);
    case MusicErrorKind::HelperProcessUnavailable:
        return QStringLiteral("本地服务不可用，请尝试重启应用");
    case MusicErrorKind::HelperProcessTimeout:
        return QStringLiteral("本地服务响应超时");
    case MusicErrorKind::HelperAuthFailed:
        return QStringLiteral("本地服务鉴权失败");
    case MusicErrorKind::RequestTimeout:
        return QStringLiteral("请求超时，请稍后重试");
    case MusicErrorKind::InvalidResponse:
        return QStringLiteral("服务器返回数据格式异常");
    case MusicErrorKind::Cancelled:
        return QStringLiteral("操作已取消");
    case MusicErrorKind::UnsupportedFormat:
        return QStringLiteral("不支持的音频格式：%1").arg(detail);
    case MusicErrorKind::FileNotFound:
        return QStringLiteral("文件不存在");
    case MusicErrorKind::Unknown:
        return detail.isEmpty() ? QStringLiteral("未知错误") : detail;
    }
    return detail;
}

} // namespace

MusicException::MusicException(MusicErrorKind kind, QString detail, int code)
    : m_kind(kind)
    , m_detail(std::move(detail))
    , m_code(code)
    , m_message(buildMessage(kind, m_detail, code))
{
}

QString MusicException::userFacingMessage() const
{
    return CTLog::sanitize(m_message);
}

bool MusicException::isRetryable() const
{
    switch (m_kind) {
    case MusicErrorKind::NetworkUnavailable:
    case MusicErrorKind::RateLimited:
    case MusicErrorKind::HelperProcessTimeout:
    case MusicErrorKind::HelperProcessUnavailable:
    case MusicErrorKind::RequestTimeout:
        return true;
    case MusicErrorKind::ApiError:
        return m_code == 429 || (m_code >= 500 && m_code <= 599);
    default:
        return false;
    }
}

bool MusicException::operator==(const MusicException& other) const
{
    return m_kind == other.m_kind && m_code == other.m_code && m_message == other.m_message;
}

void logDetachedTaskException(const std::exception_ptr& exception)
{
    try {
        if (exception) std::rethrow_exception(exception);
    } catch (const MusicException& error) {
        CTLog::general().error(QStringLiteral("未观察的异步任务失败：%1").arg(error.userFacingMessage()));
    } catch (const std::exception& error) {
        CTLog::general().error(QStringLiteral("未观察的异步任务异常：%1").arg(QString::fromUtf8(error.what())));
    } catch (...) {
        CTLog::general().error(QStringLiteral("未观察的异步任务异常"));
    }
}

} // namespace ct
