#include "Core/Platform/WindowsShortcuts.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QScopedPointer>
#include <QTextStream>

#include <cstring>
#include <string>

#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#endif

namespace ct::windowsShortcuts {
namespace {

bool failed(const QString& message, QString* error)
{
    if (error) *error = message;
    return false;
}

#ifdef Q_OS_WIN
template <typename T> struct ComRelease {
    static void cleanup(T* pointer) { if (pointer) pointer->Release(); }
};

struct Apartment {
    HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ~Apartment() { if (SUCCEEDED(result)) CoUninitialize(); }
};

QString programsDirectory()
{
    const DWORD size = GetEnvironmentVariableW(L"CLEARTONE_TEST_START_MENU_DIR", nullptr, 0);
    if (size > 0) {
        std::wstring buffer(size, L'\0');
        const DWORD length = GetEnvironmentVariableW(L"CLEARTONE_TEST_START_MENU_DIR", buffer.data(), size);
        if (length > 0 && length < size) return QString::fromWCharArray(buffer.data(), length);
        return {};
    }
    PWSTR path = nullptr;
    const HRESULT result = SHGetKnownFolderPath(FOLDERID_Programs, KF_FLAG_DEFAULT, nullptr, &path);
    const QString directory = SUCCEEDED(result) ? QString::fromWCharArray(path) : QString();
    CoTaskMemFree(path);
    return directory;
}
#endif

} // namespace

bool add(const QString& executable, const QString& programs, QString* error)
{
#ifdef Q_OS_WIN
    if (!QFileInfo(executable).isFile()) return failed(QStringLiteral("ClearTone.exe was not found."), error);
    if (programs.isEmpty() || !QDir().mkpath(programs))
        return failed(QStringLiteral("The current user Start Menu folder is unavailable."), error);
    Apartment apartment;
    if (FAILED(apartment.result) && apartment.result != RPC_E_CHANGED_MODE)
        return failed(QStringLiteral("Cannot initialize Windows shortcut services."), error);
    IShellLinkW* rawLink = nullptr;
    HRESULT result = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
        IID_IShellLinkW, reinterpret_cast<void**>(&rawLink));
    QScopedPointer<IShellLinkW, ComRelease<IShellLinkW>> link(rawLink);
    if (SUCCEEDED(result)) result = link->SetPath(executable.toStdWString().c_str());
    if (SUCCEEDED(result)) result = link->SetWorkingDirectory(QFileInfo(executable).absolutePath().toStdWString().c_str());
    if (SUCCEEDED(result)) result = link->SetIconLocation(executable.toStdWString().c_str(), 0);
    if (SUCCEEDED(result)) result = link->SetDescription(L"ClearTone portable music player");
    IPersistFile* rawFile = nullptr;
    if (SUCCEEDED(result)) result = link->QueryInterface(IID_IPersistFile, reinterpret_cast<void**>(&rawFile));
    QScopedPointer<IPersistFile, ComRelease<IPersistFile>> file(rawFile);
    if (SUCCEEDED(result)) {
        const QString path = QDir(programs).filePath(QStringLiteral("ClearTone.lnk"));
        result = file->Save(path.toStdWString().c_str(), TRUE);
    }
    if (FAILED(result)) return failed(QStringLiteral("Cannot save the Start Menu shortcut (0x%1).")
        .arg(static_cast<quint32>(result), 8, 16, QLatin1Char('0')), error);
    return true;
#else
    Q_UNUSED(executable);
    Q_UNUSED(programs);
    return failed(QStringLiteral("Start Menu shortcuts require Windows."), error);
#endif
}

bool remove(const QString& programs, QString* error)
{
    if (programs.isEmpty()) return failed(QStringLiteral("The current user Start Menu folder is unavailable."), error);
    const QString path = QDir(programs).filePath(QStringLiteral("ClearTone.lnk"));
    return !QFile::exists(path) || QFile::remove(path)
        || failed(QStringLiteral("Cannot remove the Start Menu shortcut."), error);
}

std::optional<int> runCommandLine(int argc, char** argv)
{
#ifdef Q_OS_WIN
    bool adding = false;
    bool removing = false;
    for (int index = 1; index < argc; ++index) {
        adding |= std::strcmp(argv[index], "--add-to-start-menu") == 0;
        removing |= std::strcmp(argv[index], "--remove-from-start-menu") == 0;
    }
    if (!adding && !removing) return std::nullopt;
    if (adding && removing) return 1;
    const QString directory = programsDirectory();
    std::wstring buffer(32768, L'\0');
    const DWORD length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0 || length >= buffer.size()) return 1;
    QString error;
    const bool ok = adding ? add(QString::fromWCharArray(buffer.data(), length), directory, &error)
                           : remove(directory, &error);
    if (!ok) QTextStream(stderr) << error << Qt::endl;
    return ok ? 0 : 1;
#else
    Q_UNUSED(argc);
    Q_UNUSED(argv);
    return std::nullopt;
#endif
}

} // namespace ct::windowsShortcuts
