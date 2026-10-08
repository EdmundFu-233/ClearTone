#include "Core/Networking/HTTPClient.h"

#include "Core/Logging/CTLog.h"

#include <QNetworkProxy>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSharedPointer>

namespace ct {

MusicException mapReplyError(QNetworkReply::NetworkError error, int statusCode, bool helperBacked)
{
    Q_UNUSED(statusCode);
    switch (error) {
    case QNetworkReply::ConnectionRefusedError:
    case QNetworkReply::RemoteHostClosedError:
    case QNetworkReply::ProxyConnectionRefusedError:
    case QNetworkReply::ProxyConnectionClosedError:
        return helperBacked ? MusicException::helperProcessUnavailable()
                            : MusicException::networkUnavailable();
    case QNetworkReply::HostNotFoundError:
    case QNetworkReply::UnknownNetworkError:
        return MusicException::networkUnavailable();
    case QNetworkReply::TimeoutError:
    case QNetworkReply::OperationCanceledError:
        return helperBacked ? MusicException::helperProcessTimeout() : MusicException::requestTimeout();
    case QNetworkReply::ProxyNotFoundError:
    case QNetworkReply::ProxyTimeoutError:
        return MusicException::networkUnavailable();
    case QNetworkReply::SslHandshakeFailedError:
        return MusicException::networkUnavailable();
    case QNetworkReply::TemporaryNetworkFailureError:
    case QNetworkReply::NetworkSessionFailedError:
        return MusicException::networkUnavailable();
    case QNetworkReply::ProtocolFailure:
    case QNetworkReply::ProtocolUnknownError:
        return MusicException::invalidResponse();
    default:
        return MusicException::unknown(QStringLiteral("network error %1").arg(static_cast<int>(error)));
    }
}

HTTPClient::HTTPClient(QObject* parent, bool useProxy)
    : QObject(parent)
    , m_manager(new QNetworkAccessManager(this))
{
    if (!useProxy) {
        m_manager->setProxy(QNetworkProxy(QNetworkProxy::NoProxy));
    }
    m_manager->setRedirectPolicy(QNetworkRequest::NoLessSafeRedirectPolicy);
}

Awaitable<HTTPResponse> HTTPClient::send(HTTPRequest request, CancellationToken ct)
{
    return Awaitable<HTTPResponse>{[this, request = std::move(request), ct](Callback<HTTPResponse> callback) {
        auto impl = [](HTTPClient* client, HTTPRequest request, CancellationToken ct,
                       Callback<HTTPResponse> callback) {
            QNetworkRequest networkRequest(request.url);
            networkRequest.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                QNetworkRequest::NoLessSafeRedirectPolicy);
            if (request.timeoutMs > 0) networkRequest.setTransferTimeout(request.timeoutMs);
            for (auto it = request.headers.constBegin(); it != request.headers.constEnd(); ++it) {
                networkRequest.setRawHeader(it.key().toUtf8(), it.value().toUtf8());
            }

            QNetworkReply* reply = nullptr;
            if (request.method == "POST") {
                if (!request.contentType.isEmpty()) {
                    networkRequest.setHeader(QNetworkRequest::ContentTypeHeader, request.contentType);
                }
                reply = client->m_manager->post(networkRequest, request.body);
            } else {
                reply = client->m_manager->get(networkRequest);
            }

            struct ReplyState {
                bool completed = false;
                int cancelId = 0;
                CancellationToken ct;
            };
            auto state = QSharedPointer<ReplyState>::create();
            state->ct = ct;

            const bool helperBacked = request.url.host() == QStringLiteral("127.0.0.1");
            QObject::connect(reply, &QNetworkReply::finished, reply,
                [reply, callback, state, helperBacked]() {
                    if (state->completed) {
                        reply->deleteLater();
                        return;
                    }
                    state->completed = true;
                    state->ct.unregisterCallback(state->cancelId);

                    HTTPResponse response;
                    const QVariant status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute);
                    response.statusCode = status.isValid() ? status.toInt() : 0;
                    response.body = reply->readAll();
                    const auto rawHeaders = reply->rawHeaderPairs();
                    for (const auto& pair : rawHeaders) response.headers.append(pair);

                    if (reply->error() != QNetworkReply::NoError && response.statusCode == 0) {
                        callback(Result<HTTPResponse>::failure(
                            mapReplyError(reply->error(), response.statusCode, helperBacked)));
                    } else {
                        callback(Result<HTTPResponse>::success(std::move(response)));
                    }
                    reply->deleteLater();
                });

            if (ct.canBeCancelled()) {
                state->cancelId = ct.registerCallback([reply, state] {
                    if (state->completed) return;
                    state->completed = true;
                    state->ct.unregisterCallback(state->cancelId);
                    reply->abort();
                    reply->deleteLater();
                });
                if (state->completed) {
                    // 注册时发现已取消：cancelCallback 已同步执行并清理。
                    return;
                }
            }
        };
        impl(this, std::move(request), ct, std::move(callback));
    }};
}

Awaitable<HTTPResponse> HTTPClient::get(const QUrl& url, const QHash<QString, QString>& headers,
    int timeoutMs, CancellationToken ct)
{
    HTTPRequest request;
    request.url = url;
    request.method = "GET";
    request.headers = headers;
    request.timeoutMs = timeoutMs;
    return send(std::move(request), std::move(ct));
}

Awaitable<HTTPResponse> HTTPClient::postForm(const QUrl& url, const QByteArray& formBody,
    const QHash<QString, QString>& headers, int timeoutMs, CancellationToken ct)
{
    HTTPRequest request;
    request.url = url;
    request.method = "POST";
    request.body = formBody;
    request.contentType = "application/x-www-form-urlencoded";
    request.headers = headers;
    request.timeoutMs = timeoutMs;
    return send(std::move(request), std::move(ct));
}

Awaitable<HTTPResponse> HTTPClient::postJson(const QUrl& url, const QByteArray& json, CancellationToken ct)
{
    HTTPRequest request;
    request.url = url;
    request.method = "POST";
    request.body = json;
    request.contentType = "application/json";
    request.timeoutMs = 20000;
    return send(std::move(request), std::move(ct));
}

} // namespace ct
