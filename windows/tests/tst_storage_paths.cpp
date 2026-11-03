#include <QtTest>

#include "Core/Logging/CTLog.h"
#include "Core/Persistence/StoragePaths.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QProcess>
#include <QProcessEnvironment>
#include <QTemporaryDir>

using namespace ct;

class StoragePathsTests : public QObject {
    Q_OBJECT

    QByteArray probe(const QProcessEnvironment& environment, const QString& workingDirectory,
        bool writeLog = false)
    {
        QProcess process;
        process.setProcessEnvironment(environment);
        process.setWorkingDirectory(workingDirectory);
        process.start(QCoreApplication::applicationFilePath(),
            {writeLog ? QStringLiteral("--write-log") : QStringLiteral("--storage-root")});
        if (!process.waitForFinished(10000) || process.exitCode() != 0) return {};
        return process.readAllStandardOutput().trimmed();
    }

private slots:
    void windowsDefaultFollowsExecutableInsteadOfWorkingDirectory()
    {
#ifdef Q_OS_WIN
        QTemporaryDir working;
        QVERIFY(working.isValid());
        auto environment = QProcessEnvironment::systemEnvironment();
        environment.remove(QStringLiteral("CLEARTONE_STORAGE_DIR"));
        environment.remove(QStringLiteral("CLEARTONE_TEST_STORAGE_DIR"));
        QCOMPARE(QString::fromUtf8(probe(environment, working.path())),
            QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("data")));
#else
        QSKIP("Windows portable storage policy");
#endif
    }

    void testOverrideWinsAndLogsStayInsideIt()
    {
        QTemporaryDir root;
        QVERIFY(root.isValid());
        const QString testRoot = QDir(root.path()).filePath(QStringLiteral("测试 data"));
        const QString otherRoot = QDir(root.path()).filePath(QStringLiteral("must-not-write"));
        auto environment = QProcessEnvironment::systemEnvironment();
        environment.insert(QStringLiteral("CLEARTONE_TEST_STORAGE_DIR"), testRoot);
        environment.insert(QStringLiteral("CLEARTONE_STORAGE_DIR"), otherRoot);
        QCOMPARE(QString::fromUtf8(probe(environment, root.path())), testRoot);
        probe(environment, root.path(), true);
        QVERIFY(QFile::exists(QDir(testRoot).filePath(QStringLiteral("logs/cleartone.log"))));
        QVERIFY(!QDir(otherRoot).exists());
    }

    void explicitRelativeOverrideResolvesBeforeHelperLaunch()
    {
        QTemporaryDir working;
        QVERIFY(working.isValid());
        auto environment = QProcessEnvironment::systemEnvironment();
        environment.remove(QStringLiteral("CLEARTONE_TEST_STORAGE_DIR"));
        environment.insert(QStringLiteral("CLEARTONE_STORAGE_DIR"), QStringLiteral("custom-data"));
        QCOMPARE(QString::fromUtf8(probe(environment, working.path())),
            QDir(working.path()).filePath(QStringLiteral("custom-data")));
    }
};

int main(int argc, char** argv)
{
    QCoreApplication app(argc, argv);
    if (app.arguments().contains(QStringLiteral("--storage-root"))) {
        QFile output;
        if (!output.open(stdout, QIODevice::WriteOnly)) return 1;
        output.write(StoragePaths::root().toUtf8());
        return 0;
    }
    if (app.arguments().contains(QStringLiteral("--write-log"))) {
        CTLog::general().info(QStringLiteral("isolated portable log probe"));
        return 0;
    }
    StoragePathsTests tests;
    return QTest::qExec(&tests, argc, argv);
}

#include "tst_storage_paths.moc"
