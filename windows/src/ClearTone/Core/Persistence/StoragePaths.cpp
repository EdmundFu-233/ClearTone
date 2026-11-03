#include "Core/Persistence/StoragePaths.h"

#include <QDir>
#include <QCoreApplication>
#include <QStandardPaths>

namespace ct {

QString StoragePaths::root()
{
    static const QString resolved = [] {
        const QString testDir = qEnvironmentVariable("CLEARTONE_TEST_STORAGE_DIR");
        if (!testDir.isEmpty()) return QDir(testDir).absolutePath();
        const QString overrideDir = qEnvironmentVariable("CLEARTONE_STORAGE_DIR");
        if (!overrideDir.isEmpty()) return QDir(overrideDir).absolutePath();

#ifdef Q_OS_WIN
        return QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("data"));
#else
        const QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        return QDir(base).filePath(QStringLiteral("ClearTone"));
#endif
    }();
    return resolved;
}

} // namespace ct
