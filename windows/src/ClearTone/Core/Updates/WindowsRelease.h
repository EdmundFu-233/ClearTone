#pragma once

#include <QByteArray>
#include <QString>
#include <QUrl>

#include <optional>

namespace ct::updates {

struct WindowsRelease {
    QString version;
    QUrl downloadUrl;
};

// Accept only stable semantic versions and the repository's x64 release asset.
std::optional<WindowsRelease> parseLatestRelease(const QByteArray& response);
bool isNewer(const QString& latest, const QString& installed);

} // namespace ct::updates
