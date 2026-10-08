#pragma once

#include <QString>

namespace ct {

class LogChannel {
public:
    explicit LogChannel(QString category) : m_category(std::move(category)) {}

    void info(const QString& message) const { write(QStringLiteral("INFO"), message); }
    void warn(const QString& message) const { write(QStringLiteral("WARN"), message); }
    void error(const QString& message) const { write(QStringLiteral("ERROR"), message); }
    void debug(const QString& message) const { write(QStringLiteral("DEBUG"), message); }

private:
    void write(const QString& level, const QString& message) const;

    QString m_category;
};

class CTLog {
public:
    static QString sanitize(const QString& message);
    static QString redact(const QString& value);

    static LogChannel& general();
    static LogChannel& network();
    static LogChannel& playback();
    static LogChannel& helper();
    static LogChannel& render();
    static LogChannel& security();
};

} // namespace ct
