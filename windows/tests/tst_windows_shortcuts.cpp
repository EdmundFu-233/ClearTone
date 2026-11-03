#include <QtTest>

#include "Core/Platform/WindowsShortcuts.h"

#include <QDir>
#include <QFile>
#include <QTemporaryDir>

#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#endif

using namespace ct;

class WindowsShortcutsTests : public QObject {
    Q_OBJECT

private slots:
    void unicodeTargetWorkingDirectoryAndIconSurviveRoundTrip()
    {
#ifndef Q_OS_WIN
        QSKIP("Windows shell shortcut API");
#else
        QTemporaryDir root;
        QVERIFY(root.isValid());
        const QString app = root.filePath(QStringLiteral("便携 & ' [x] ! %"));
        const QString programs = root.filePath(QStringLiteral("开始菜单 Programs"));
        QVERIFY(QDir().mkpath(app));
        const QString executable = QDir(app).filePath(QStringLiteral("ClearTone.exe"));
        QVERIFY(QFile::copy(QCoreApplication::applicationFilePath(), executable));
        QString error;
        QVERIFY2(windowsShortcuts::add(executable, programs, &error), qPrintable(error));
        QVERIFY2(windowsShortcuts::add(executable, programs, &error), qPrintable(error));
        const HRESULT apartment = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        IShellLinkW* link = nullptr;
        IPersistFile* file = nullptr;
        auto cleanup = qScopeGuard([&] {
            if (file) file->Release();
            if (link) link->Release();
            if (SUCCEEDED(apartment)) CoUninitialize();
        });
        QVERIFY(SUCCEEDED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
            IID_IShellLinkW, reinterpret_cast<void**>(&link))));
        QVERIFY(SUCCEEDED(link->QueryInterface(IID_IPersistFile, reinterpret_cast<void**>(&file))));
        const QString path = QDir(programs).filePath(QStringLiteral("ClearTone.lnk"));
        QVERIFY(SUCCEEDED(file->Load(path.toStdWString().c_str(), STGM_READ)));
        wchar_t buffer[32768]{};
        QVERIFY(SUCCEEDED(link->GetPath(buffer, 32768, nullptr, SLGP_RAWPATH)));
        QCOMPARE(QDir::fromNativeSeparators(QString::fromWCharArray(buffer)), executable);
        QVERIFY(SUCCEEDED(link->GetWorkingDirectory(buffer, 32768)));
        QCOMPARE(QDir::fromNativeSeparators(QString::fromWCharArray(buffer)), app);
        int index = -1;
        QVERIFY(SUCCEEDED(link->GetIconLocation(buffer, 32768, &index)));
        QCOMPARE(QDir::fromNativeSeparators(QString::fromWCharArray(buffer)), executable);
        QCOMPARE(index, 0);
        file->Release();
        file = nullptr;
        link->Release();
        link = nullptr;
        QVERIFY(windowsShortcuts::remove(programs, &error));
        QVERIFY(windowsShortcuts::remove(programs, &error));
        QVERIFY(!QFile::exists(path));
        QVERIFY(QFile::exists(executable));
#endif
    }

    void missingExecutableDoesNotCreateShortcut()
    {
#ifndef Q_OS_WIN
        QSKIP("Windows shell shortcut API");
#else
        QTemporaryDir root;
        QString error;
        QVERIFY(!windowsShortcuts::add(root.filePath("missing.exe"), root.filePath("Programs"), &error));
        QVERIFY(!error.isEmpty());
        QVERIFY(!QFile::exists(root.filePath("Programs/ClearTone.lnk")));
#endif
    }
};

QTEST_GUILESS_MAIN(WindowsShortcutsTests)
#include "tst_windows_shortcuts.moc"
