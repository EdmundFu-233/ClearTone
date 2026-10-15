#include "Core/Updates/WindowsRelease.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>

namespace ct::updates {

namespace {

std::optional<QList<int>> versionParts(const QString& version)
{
    static const QRegularExpression pattern(QStringLiteral("^v?(\\d+)\\.(\\d+)\\.(\\d+)$"));
    const auto match = pattern.match(version);
    if (!match.hasMatch()) return std::nullopt;
    QList<int> parts;
    for (int i = 1; i <= 3; ++i) {
        bool ok = false;
        const int number = match.captured(i).toInt(&ok);
        if (!ok) return std::nullopt;
        parts.append(number);
    }
    return parts;
}

} // namespace

std::optional<WindowsRelease> parseLatestRelease(const QByteArray& response)
{
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(response, &error);
    if (error.error != QJsonParseError::NoError || !document.isObject()) return std::nullopt;
    const QJsonObject object = document.object();
    const QString tag = object.value(QStringLiteral("tag_name")).toString();
    if (!versionParts(tag) || object.value(QStringLiteral("draft")).toBool()
        || object.value(QStringLiteral("prerelease")).toBool()) return std::nullopt;

    for (const QJsonValue& value : object.value(QStringLiteral("assets")).toArray()) {
        const QJsonObject asset = value.toObject();
        if (asset.value(QStringLiteral("name")).toString() != QStringLiteral("ClearTone-win-x64.zip"))
            continue;
        const QUrl url(asset.value(QStringLiteral("browser_download_url")).toString());
        if (url.scheme() != QStringLiteral("https") || url.host() != QStringLiteral("github.com")
            || url.port() != -1 || !url.userInfo().isEmpty()
            || !url.path().startsWith(QStringLiteral("/EdmundFu-233/ClearTone/releases/download/"))
            || !url.path().endsWith(QStringLiteral("/ClearTone-win-x64.zip"))) continue;
        return WindowsRelease{tag, url};
    }
    return WindowsRelease{tag, {}};
}

bool isNewer(const QString& latest, const QString& installed)
{
    const auto newParts = versionParts(latest);
    const auto oldParts = versionParts(installed);
    if (!newParts || !oldParts) return false;
    return *newParts > *oldParts;
}

} // namespace ct::updates
