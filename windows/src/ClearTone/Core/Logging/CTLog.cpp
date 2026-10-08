#include "Core/Logging/CTLog.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QMutex>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QTextStream>

namespace ct {

namespace {

QString secretKeysPattern()
{
    static const QString pattern = QStringLiteral(
        "MUSIC_U|MUSIC_A|MUSIC_R|MUSIC_H|__csrf|__remember_me|NMTID|cookie|set-cookie|token|"
        "access_token|refresh_token|key|password|pwd|auth|authorization|secret|session");
    return pattern;
}

const QVector<QPair<QRegularExpression, QString>>& sanitizeRules()
{
    static const QVector<QPair<QRegularExpression, QString>> rules = [] {
        QVector<QPair<QRegularExpression, QString>> result;
        result.append({
            QRegularExpression(QStringLiteral(R"(\b((?:authorization|auth)\s*[=:]\s*)[^\n;,"'}]+)"),
                               QRegularExpression::CaseInsensitiveOption),
            QStringLiteral("\\1***"),
        });
        result.append({
            QRegularExpression(
                QStringLiteral("\"(%1)\"\\s*:\\s*(?:\"[^\"]*\"|[^,}\\s]+)").arg(secretKeysPattern()),
                QRegularExpression::CaseInsensitiveOption),
            QStringLiteral("\"\\1\":\"***\""),
        });
        result.append({
            QRegularExpression(
                QStringLiteral(R"(\b((?:%1)\s*[=:]\s*)[^;,\s&}"']+)").arg(secretKeysPattern()),
                QRegularExpression::CaseInsensitiveOption),
            QStringLiteral("\\1***"),
        });
        return result;
    }();
    return rules;
}

QString logFilePath()
{
    static const QString path = [] {
        const QString root = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation);
        if (root.isEmpty()) return QString();
        QDir dir(root);
        dir.mkpath(QStringLiteral("logs"));
        return dir.filePath(QStringLiteral("logs/cleartone.log"));
    }();
    return path;
}

QMutex& fileMutex()
{
    static QMutex mutex;
    return mutex;
}

} // namespace

QString CTLog::sanitize(const QString& message)
{
    QString result = message;
    for (const auto& [pattern, replacement] : sanitizeRules()) {
        result.replace(pattern, replacement);
    }
    return result;
}

QString CTLog::redact(const QString& value)
{
    if (value.isEmpty()) return QStringLiteral("<empty>");
    if (value.size() <= 8) return QStringLiteral("***");
    return value.left(4) + QStringLiteral("...") + value.right(4);
}

void LogChannel::write(const QString& level, const QString& message) const
{
    const QString safe = CTLog::sanitize(message);
    const QString line = QStringLiteral("%1 [%2] [%3] %4")
                             .arg(QDateTime::currentDateTime().toString(QStringLiteral("yyyy-MM-dd HH:mm:ss.zzz")),
                                  level, m_category, safe);

    QTextStream stream(stdout);
    stream << line << Qt::endl;

    const QString path = logFilePath();
    if (path.isEmpty()) return;
    QMutexLocker locker(&fileMutex());
    QFile file(path);
    if (!file.open(QIODevice::Append | QIODevice::Text)) return;
    QTextStream out(&file);
    out << line << Qt::endl;
}

LogChannel& CTLog::general()
{
    static LogChannel channel(QStringLiteral("general"));
    return channel;
}

LogChannel& CTLog::network()
{
    static LogChannel channel(QStringLiteral("network"));
    return channel;
}

LogChannel& CTLog::playback()
{
    static LogChannel channel(QStringLiteral("playback"));
    return channel;
}

LogChannel& CTLog::helper()
{
    static LogChannel channel(QStringLiteral("helper"));
    return channel;
}

LogChannel& CTLog::render()
{
    static LogChannel channel(QStringLiteral("render"));
    return channel;
}

LogChannel& CTLog::security()
{
    static LogChannel channel(QStringLiteral("security"));
    return channel;
}

} // namespace ct
