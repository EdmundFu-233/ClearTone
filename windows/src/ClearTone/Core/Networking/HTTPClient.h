#pragma once

#include "Core/Async.h"

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QObject>
#include <QPair>
#include <QUrl>

#include <optional>

namespace ct {

struct HTTPResponse {
    int statusCode = 0;
    QByteArray body;
    QList<QPair<QByteArray, QByteArray>> headers;

    QByteArray header(const QByteArray& name) const
    {
        for (const auto& [key, value] : headers) {
            if (key.compare(name, Qt::CaseInsensitive) == 0) return value;
        }
        return {};
    }
};

struct HTTPRequest {
    QUrl url;
    QByteArray method = "GET";
    QByteArray body;
    QByteArray contentType;
    QHash<QString, QString> headers;
    int timeoutMs = 20000;
};

class HTTPClient : public QObject {
    Q_OBJECT

public:
    explicit HTTPClient(QObject* parent = nullptr, bool useProxy = false);

    Awaitable<HTTPResponse> send(HTTPRequest request, CancellationToken ct);

    Awaitable<HTTPResponse> get(const QUrl& url, const QHash<QString, QString>& headers,
        int timeoutMs, CancellationToken ct);

    Awaitable<HTTPResponse> postForm(const QUrl& url, const QByteArray& formBody,
        const QHash<QString, QString>& headers, int timeoutMs, CancellationToken ct);

    Awaitable<HTTPResponse> postJson(const QUrl& url, const QByteArray& json, CancellationToken ct);

private:
    QNetworkAccessManager* m_manager;
};

// 把 QNetworkReply 的错误映射为 MusicException。
MusicException mapReplyError(QNetworkReply::NetworkError error, int statusCode, bool helperBacked);

} // namespace ct
