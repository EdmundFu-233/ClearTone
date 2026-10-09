#include "Core/Networking/HelperProcessManager.h"

#include "Core/Logging/CTLog.h"

#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QRandomGenerator>
#include <QStandardPaths>
#include <QUuid>

#include <algorithm>

namespace ct {

namespace {

QString helperLogPath()
{
    const QString root = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation);
    if (root.isEmpty()) return {};
    QDir dir(root);
    dir.mkpath(QStringLiteral("logs"));
    return dir.filePath(QStringLiteral("logs/helper.log"));
}

} // namespace

HelperProcessManager& HelperProcessManager::shared()
{
    static HelperProcessManager manager;
    return manager;
}

HelperProcessManager::HelperProcessManager(QObject* parent)
    : QObject(parent)
    , m_healthClient(std::make_unique<HTTPClient>())
{
    m_monitorTimer = new QTimer(this);
    m_monitorTimer->setInterval(15000);
    connect(m_monitorTimer, &QTimer::timeout, this, [this] {
        if (m_stopping) return;
        const bool alive = isProcessAlive();
        detach(monitorHelper(alive));
    });

    m_restartTimer = new QTimer(this);
    m_restartTimer->setSingleShot(true);
    connect(m_restartTimer, &QTimer::timeout, this, [this] {
        detach(restartAfterFailure(m_resumeMonitoringOnFailure));
    });
}

Task<void> HelperProcessManager::monitorHelper(bool alive)
{
    const bool healthy = co_await checkHealth();
    if (m_stopping) co_return;
    if (!alive || !healthy) {
        CTLog::helper().warn(
            QStringLiteral("辅助进程异常 (alive=%1, healthy=%2)，尝试重启").arg(alive).arg(healthy));
        m_monitoring = false;
        m_monitorTimer->stop();
        setState({HelperState::Kind::Failed, 0, QStringLiteral("辅助进程异常退出")});
        stopProcess();
        scheduleRestart(500, true);
    }
}

Task<void> HelperProcessManager::restartAfterFailure(bool resumeMonitoring)
{
    try {
        co_await start(CancellationToken::none());
    } catch (const MusicException& error) {
        CTLog::helper().error(
            QStringLiteral("健康检查自动重启失败: %1").arg(error.userFacingMessage()));
        setState({HelperState::Kind::Failed, 0, QStringLiteral("辅助进程异常退出")});
        if (resumeMonitoring) startHealthMonitoring();
    }
}

QString HelperProcessManager::runtimeRoot()
{
    const QByteArray overrideRoot = qgetenv("CLEARTONE_HELPER_ROOT");
    if (!overrideRoot.isEmpty()) return QString::fromUtf8(overrideRoot);
    return QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("helper"));
}

QString HelperProcessManager::resolveRuntimeDirectory()
{
    const QString bundled = runtimeRoot();
    if (QDir(bundled).exists()) return bundled;

    QDir directory(QCoreApplication::applicationDirPath());
    for (int i = 0; i < 8; ++i) {
        const QString candidate =
            directory.filePath(QStringLiteral("ClearTone/Resources/HelperRuntime"));
        if (QDir(candidate).exists()) return candidate;
        if (!directory.cdUp()) break;
    }
    return bundled;
}

QString HelperProcessManager::resolveNodeBinary(const QString& runtimeDir)
{
    const QByteArray nodeOverride = qgetenv("CLEARTONE_HELPER_NODE");
    if (!nodeOverride.isEmpty()) {
        const QString candidate = QString::fromUtf8(nodeOverride);
        if (QFile::exists(candidate)) return candidate;
    }

    const QStringList candidates = {
#ifdef Q_OS_WIN
        QDir(runtimeDir).filePath(QStringLiteral("bin/node.exe")),
        QDir(runtimeDir).filePath(QStringLiteral("bin/node")),
#else
        QDir(runtimeDir).filePath(QStringLiteral("bin/node")),
        QDir(runtimeDir).filePath(QStringLiteral("bin/node.exe")),
#endif
    };
    for (const QString& candidate : candidates) {
        if (QFile::exists(candidate)) return candidate;
    }
    return candidates.first();
}

void HelperProcessManager::setState(const HelperState& state)
{
    m_state = state;
    emit stateChanged();
}

Task<void> HelperProcessManager::startIfNeeded(CancellationToken ct)
{
    co_await start(ct);
}

Task<void> HelperProcessManager::start(CancellationToken ct)
{
    if (m_state.kind == HelperState::Kind::Running) co_return;

    if (m_state.kind == HelperState::Kind::Starting) {
        QElapsedTimer timer;
        timer.start();
        while (m_state.kind == HelperState::Kind::Starting && timer.elapsed() < 35000) {
            co_await Delay(100, ct);
        }
        if (m_state.kind != HelperState::Kind::Running) {
            throw MusicException::helperProcessTimeout();
        }
        co_return;
    }

    co_await performStart(ct);
}

Task<void> HelperProcessManager::performStart(CancellationToken ct)
{
    setState({HelperState::Kind::Starting, 0, {}});
    m_lastError.clear();

    const QString runtimeDir = resolveRuntimeDirectory();
    if (!QDir(runtimeDir).exists()) {
        const QString message =
            QStringLiteral("辅助进程运行时未找到: %1。请先运行 scripts/setup-helper.sh 或 windows/scripts/fetch-node-win.sh")
                .arg(runtimeDir);
        setState({HelperState::Kind::Failed, 0, message});
        m_lastError = message;
        throw MusicException::helperProcessUnavailable();
    }

    const QString nodeBinary = resolveNodeBinary(runtimeDir);
    const QString apiDir = QDir(runtimeDir).filePath(QStringLiteral("api"));
    const QString apiScript = QDir(apiDir).filePath(QStringLiteral("app.js"));
    if (!QFile::exists(nodeBinary) || !QFile::exists(apiScript)) {
        const QString message = QStringLiteral("辅助进程文件不完整（缺少 node 或 app.js）");
        setState({HelperState::Kind::Failed, 0, message});
        m_lastError = message;
        throw MusicException::helperProcessUnavailable();
    }

    m_port = QRandomGenerator::global()->bounded(21000, 29001);
    m_authToken = QUuid::createUuid().toString(QUuid::WithoutBraces);

    const QString logPath = helperLogPath();
    if (!logPath.isEmpty()) rotateLogIfNeeded(logPath);

    auto* process = new QProcess(this);
    m_process = process;

    QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
    environment.insert(QStringLiteral("PORT"), QString::number(m_port));
    environment.insert(QStringLiteral("CT_AUTH_TOKEN"), m_authToken);
    environment.insert(QStringLiteral("HOST"), QStringLiteral("127.0.0.1"));
    environment.insert(QStringLiteral("NODE_ENV"), QStringLiteral("production"));
    for (const char* key : {"http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "no_proxy", "NO_PROXY"}) {
        environment.insert(QString::fromLatin1(key), QString());
    }

    process->setProcessEnvironment(environment);
    process->setWorkingDirectory(apiDir);
    process->setProgram(nodeBinary);
    process->setArguments({apiScript});
    process->setProcessChannelMode(QProcess::SeparateChannels);

    connect(process, &QProcess::readyReadStandardOutput, this, [this, process] {
        appendProcessLog(QString::fromUtf8(process->readAllStandardOutput()));
    });
    connect(process, &QProcess::readyReadStandardError, this, [this, process] {
        appendProcessLog(QString::fromUtf8(process->readAllStandardError()));
    });
    connect(process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
        [this, process](int code, QProcess::ExitStatus) {
            if (m_stopping) return;
            if (process != m_process) return;
            CTLog::helper().warn(QStringLiteral("辅助进程意外退出，code: %1").arg(code));
            setState({HelperState::Kind::Failed, 0, QStringLiteral("辅助进程意外退出 (code %1)").arg(code)});
            cleanup();
            scheduleRestart(1000, false);
        });

    process->start();
    if (!process->waitForStarted(10000)) {
        const QString message = QStringLiteral("启动失败: %1").arg(process->errorString());
        stopProcess();
        setState({HelperState::Kind::Failed, 0, message});
        m_lastError = message;
        throw MusicException::helperProcessUnavailable();
    }

    try {
        // Node 冷启动在低配设备/ARM 上可能超过 15 秒，给足 30 秒。
        co_await waitForHealthy(30000, ct);
    } catch (...) {
        stopProcess();
        setState({HelperState::Kind::Failed, 0, QStringLiteral("健康检查超时")});
        m_lastError = QStringLiteral("本地服务启动超时，请重试");
        // 冷启动偶发超时：自动重试一次，失败则交给调用方。
        scheduleRestart(1000, false);
        throw MusicException::helperProcessTimeout();
    }

    setState({HelperState::Kind::Running, m_port, {}});
    CTLog::helper().info(QStringLiteral("辅助进程启动成功，端口 %1").arg(m_port));
    startHealthMonitoring();
}

Task<void> HelperProcessManager::waitForHealthy(int timeoutMs, CancellationToken ct)
{
    QElapsedTimer timer;
    timer.start();
    while (timer.elapsed() < timeoutMs) {
        if (ct.isCancellationRequested()) throw MusicException::cancelled();
        if (co_await checkHealth()) co_return;
        co_await Delay(300, ct);
    }
    throw MusicException::helperProcessTimeout();
}

Task<bool> HelperProcessManager::checkHealth()
{
    const int port = m_port;
    const QString token = m_authToken;
    if (port <= 0) co_return false;
    const QUrl url(QStringLiteral("http://127.0.0.1:%1/ct_health").arg(port));
    try {
        const HTTPResponse response = co_await m_healthClient->get(
            url, {{QStringLiteral("X-CT-Token"), token}}, 2000, CancellationToken::none());
        co_return response.statusCode == 200;
    } catch (...) {
        co_return false;
    }
}

void HelperProcessManager::stop()
{
    m_monitoring = false;
    if (m_monitorTimer) m_monitorTimer->stop();
    if (m_restartTimer) m_restartTimer->stop();
    stopProcess();
}

Task<void> HelperProcessManager::restart(CancellationToken ct)
{
    stopProcess();
    co_await Delay(500, ct);
    co_await start(ct);
}

void HelperProcessManager::stopProcess()
{
    m_stopping = true;
    if (m_process != nullptr) {
        QProcess* process = m_process;
        if (process->state() != QProcess::NotRunning) {
            process->terminate();
            if (!process->waitForFinished(2000)) {
                process->kill();
                process->waitForFinished(1000);
            }
        }
        process->deleteLater();
        m_process = nullptr;
    }
    cleanup();
    m_stopping = false;

    if (m_restartTimer) m_restartTimer->stop();
    setState({HelperState::Kind::Stopped, 0, {}});
    CTLog::helper().info(QStringLiteral("辅助进程已停止"));
}

void HelperProcessManager::cleanup()
{
    m_port = 0;
    m_authToken.clear();
}

QString HelperProcessManager::percentEncodedQuery(const QHash<QString, QString>& query)
{
    QStringList keys = query.keys();
    std::sort(keys.begin(), keys.end());
    QStringList pairs;
    pairs.reserve(keys.size());
    for (const QString& key : keys) {
        pairs.append(QString::fromUtf8(QUrl::toPercentEncoding(key)) + QStringLiteral("=")
            + QString::fromUtf8(QUrl::toPercentEncoding(query.value(key))));
    }
    return pairs.join(QStringLiteral("&"));
}

Result<QUrl> HelperProcessManager::makeURL(const QString& path, const QHash<QString, QString>& query) const
{
    if (m_state.kind != HelperState::Kind::Running) {
        return Result<QUrl>::failure(MusicException::helperProcessUnavailable());
    }
    QString url = QStringLiteral("http://127.0.0.1:%1%2").arg(m_port).arg(path);
    if (!query.isEmpty()) {
        url += QStringLiteral("?") + percentEncodedQuery(query);
    }
    return Result<QUrl>::success(QUrl(url));
}

QHash<QString, QString> HelperProcessManager::authHeaders() const
{
    if (m_authToken.isEmpty()) return {};
    return {{QStringLiteral("X-CT-Token"), m_authToken}};
}

void HelperProcessManager::startHealthMonitoring()
{
    m_monitoring = true;
    m_monitorTimer->start();
}

bool HelperProcessManager::isProcessAlive() const
{
    return m_process != nullptr && m_process->state() != QProcess::NotRunning;
}

void HelperProcessManager::scheduleRestart(int delayMs, bool resumeMonitoringOnFailure)
{
    m_resumeMonitoringOnFailure = resumeMonitoringOnFailure;
    m_restartTimer->start(delayMs);
}

void HelperProcessManager::appendProcessLog(const QString& line)
{
    const QString logPath = helperLogPath();
    if (logPath.isEmpty() || line.isEmpty()) return;
    QFile file(logPath);
    if (!file.open(QIODevice::Append | QIODevice::Text)) return;
    file.write(CTLog::sanitize(line).toUtf8());
    if (!line.endsWith(QLatin1Char('\n'))) file.write("\n");
}

void HelperProcessManager::rotateLogIfNeeded(const QString& path, qint64 maxBytes)
{
    const QFileInfo info(path);
    if (!info.exists() || info.size() <= maxBytes) return;
    const QString rotated = path + QStringLiteral(".1");
    QFile::remove(rotated);
    QFile::rename(path, rotated);
}

} // namespace ct
