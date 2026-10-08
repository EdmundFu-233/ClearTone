#include "Core/Persistence/StoragePaths.h"

#include <QDir>
#include <QStandardPaths>

namespace ct {

QString StoragePaths::root()
{
    static const QString resolved = [] {
        const QByteArray overrideDir = qgetenv("CLEARTONE_STORAGE_DIR");
        if (!overrideDir.isEmpty()) return QString::fromUtf8(overrideDir);
        const QByteArray testDir = qgetenv("CLEARTONE_TEST_STORAGE_DIR");
        if (!testDir.isEmpty()) return QString::fromUtf8(testDir);

        const QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        return QDir(base).filePath(QStringLiteral("ClearTone"));
    }();
    return resolved;
}

} // namespace ct
