#pragma once

#include "Core/Async.h"
#include "Core/Networking/HTTPClient.h"

#include <QHash>
#include <QObject>
#include <QProcess>
#include <QTimer>
#include <QUrl>

namespace ct {

struct HelperState {
    enum class Kind {
        Stopped,
        Starting,
        Running,
        Failed,
    };

    Kind kind = Kind::Stopped;
    int port = 0;
    QString message;

    bool isRunning() const { return kind == Kind::Running; }
    bool isFailed() const { return kind == Kind::Failed; }
};

class HelperProcessManager : public QObject {
    Q_OBJECT

public:
    static HelperProcessManager& shared();

    HelperState state() const { return m_state; }
    QString lastError() const { return m_lastError; }
    QString authToken() const { return m_authToken; }

    static QString runtimeRoot();
    static QString resolveRuntimeDirectory();
    static QString resolveNodeBinary(const QString& runtimeDir);

    Task<void> startIfNeeded(CancellationToken ct);
    Task<void> start(CancellationToken ct);
    void stop();
    Task<void> restart(CancellationToken ct);

    Result<QUrl> makeURL(const QString& path, const QHash<QString, QString>& query = {}) const;
    static QString percentEncodedQuery(const QHash<QString, QString>& query);
    QHash<QString, QString> authHeaders() const;

signals:
    void stateChanged();

private:
    explicit HelperProcessManager(QObject* parent = nullptr);

    Task<void> performStart(CancellationToken ct);
    Task<void> waitForHealthy(int timeoutMs, CancellationToken ct);
    Task<bool> checkHealth();
    void setState(const HelperState& state);
    void stopProcess();
    void cleanup();
    void startHealthMonitoring();
    void scheduleRestart(int delayMs, bool resumeMonitoringOnFailure);
    void appendProcessLog(const QString& line);
    bool isProcessAlive() const;
    static void rotateLogIfNeeded(const QString& path, qint64 maxBytes = 5 * 1024 * 1024);

    HelperState m_state;
    QString m_lastError;
    QProcess* m_process = nullptr;
    int m_port = 0;
    QString m_authToken;
    bool m_stopping = false;
    bool m_monitoring = false;
    bool m_resumeMonitoringOnFailure = false;
    std::unique_ptr<HTTPClient> m_healthClient;
    QTimer* m_monitorTimer = nullptr;
    QTimer* m_restartTimer = nullptr;
};

} // namespace ct
