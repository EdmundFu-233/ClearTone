#include "Core/Security/NeteaseCookieNormalizer.h"

#include <QSet>
#include <QStringList>

namespace ct {

QString NeteaseCookieNormalizer::normalize(const QString& raw)
{
    static const QSet<QString> attributeNames = {
        QStringLiteral("expires"), QStringLiteral("max-age"), QStringLiteral("path"),
        QStringLiteral("domain"), QStringLiteral("secure"), QStringLiteral("httponly"),
        QStringLiteral("samesite"), QStringLiteral("priority"), QStringLiteral("comment"),
        QStringLiteral("version"),
    };
    // 属性名大小写不敏感，QSet 以精确大小写比较，因此统一小写后查询。
    QSet<QString> seen;
    QStringList pairs;

    const QStringList segments = raw.split(QLatin1Char(';'), Qt::SkipEmptyParts);
    for (const QString& segment : segments) {
        const QString item = segment.trimmed();
        if (item.isEmpty()) continue;
        const qsizetype separator = item.indexOf(QLatin1Char('='));
        if (separator < 0) continue;
        const QString name = item.left(separator).trimmed();
        const QString value = item.mid(separator + 1).trimmed();
        if (name.isEmpty() || value.isEmpty()) continue;
        if (attributeNames.contains(name.toLower())) continue;
        if (seen.contains(name)) continue;
        seen.insert(name);
        pairs.append(name + QLatin1Char('=') + value);
    }

    return pairs.join(QStringLiteral("; "));
}

QString NeteaseCookieNormalizer::normalized(const QString& raw)
{
    const QString result = normalize(raw);
    return result == raw.trimmed() ? raw : result;
}

} // namespace ct
