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

// Accept stable two- or three-part versions and only this repository's asset for the current CPU.
std::optional<WindowsRelease> parseLatestRelease(const QByteArray& response);
bool isNewer(const QString& latest, const QString& installed);

} // namespace ct::updates
