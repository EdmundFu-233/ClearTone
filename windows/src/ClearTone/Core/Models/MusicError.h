#pragma once

#include <QString>

#include <exception>

namespace ct {

enum class MusicErrorKind {
    NotLoggedIn,
    SessionExpired,
    NetworkUnavailable,
    RateLimited,
    SongUnavailable,
    NoPlayableURL,
    ApiError,
    HelperProcessUnavailable,
    HelperProcessTimeout,
    HelperAuthFailed,
    RequestTimeout,
    InvalidResponse,
    Cancelled,
    UnsupportedFormat,
    FileNotFound,
    Unknown,
};

class MusicException {
public:
    MusicException(MusicErrorKind kind, QString detail = {}, int code = 0);

    MusicErrorKind kind() const { return m_kind; }
    int code() const { return m_code; }
    const QString& detail() const { return m_detail; }
    const QString& message() const { return m_message; }

    QString userFacingMessage() const;
    bool isRetryable() const;
    bool isCancelled() const { return m_kind == MusicErrorKind::Cancelled; }

    bool operator==(const MusicException& other) const;
    bool operator!=(const MusicException& other) const { return !(*this == other); }

    static MusicException notLoggedIn() { return {MusicErrorKind::NotLoggedIn}; }
    static MusicException sessionExpired() { return {MusicErrorKind::SessionExpired}; }
    static MusicException networkUnavailable() { return {MusicErrorKind::NetworkUnavailable}; }
    static MusicException rateLimited() { return {MusicErrorKind::RateLimited}; }
    static MusicException noPlayableURL() { return {MusicErrorKind::NoPlayableURL}; }
    static MusicException helperProcessUnavailable() { return {MusicErrorKind::HelperProcessUnavailable}; }
    static MusicException helperProcessTimeout() { return {MusicErrorKind::HelperProcessTimeout}; }
    static MusicException helperAuthFailed() { return {MusicErrorKind::HelperAuthFailed}; }
    static MusicException requestTimeout() { return {MusicErrorKind::RequestTimeout}; }
    static MusicException invalidResponse() { return {MusicErrorKind::InvalidResponse}; }
    static MusicException cancelled() { return {MusicErrorKind::Cancelled}; }
    static MusicException fileNotFound() { return {MusicErrorKind::FileNotFound}; }
    static MusicException songUnavailable(const QString& reason)
    {
        return {MusicErrorKind::SongUnavailable, reason};
    }
    static MusicException apiError(int code, const QString& message)
    {
        return {MusicErrorKind::ApiError, message, code};
    }
    static MusicException unsupportedFormat(const QString& format)
    {
        return {MusicErrorKind::UnsupportedFormat, format};
    }
    static MusicException unknown(const QString& detail) { return {MusicErrorKind::Unknown, detail}; }

private:
    MusicErrorKind m_kind;
    QString m_detail;
    int m_code;
    QString m_message;
};

void logDetachedTaskException(const std::exception_ptr& exception);

} // namespace ct
