#include "Core/Security/CredentialStore.h"

#include "Core/Logging/CTLog.h"
#include "Core/Persistence/StoragePaths.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>

#ifdef Q_OS_WIN
#include <windows.h>
#include <wincrypt.h>
#endif

namespace ct {

CredentialStore& CredentialStore::shared()
{
    static CredentialStore store;
    return store;
}

QString CredentialStore::storageRoot() { return StoragePaths::root(); }

CredentialStore::CredentialStore(QString path)
    : m_path(path.isEmpty() ? QDir(storageRoot()).filePath(QStringLiteral("credentials.json")) : std::move(path))
{
}

QString CredentialStore::nameOf(CredentialKey key)
{
    switch (key) {
    case CredentialKey::NeteaseCookie:
        return QStringLiteral("netease_cookie");
    case CredentialKey::NeteaseUserID:
        return QStringLiteral("netease_user_id");
    case CredentialKey::HelperAuthToken:
        return QStringLiteral("helper_auth_token");
    }
    return QStringLiteral("helper_auth_token");
}

std::optional<QString> CredentialStore::load(CredentialKey key)
{
    ensureLoaded();
    const auto iterator = m_values.constFind(nameOf(key));
    if (iterator == m_values.constEnd()) return std::nullopt;
    return *iterator;
}

void CredentialStore::save(const QString& value, CredentialKey key)
{
    ensureLoaded();
    m_values[nameOf(key)] = value;
    persist();
}

void CredentialStore::remove(CredentialKey key)
{
    ensureLoaded();
    if (m_values.remove(nameOf(key)) > 0) persist();
}

bool CredentialStore::has(CredentialKey key)
{
    ensureLoaded();
    return m_values.contains(nameOf(key));
}

void CredentialStore::ensureLoaded()
{
    if (m_loaded) return;
    m_loaded = true;
    QFile file(m_path);
    if (!file.exists()) return;
    if (!file.open(QIODevice::ReadOnly)) return;
    const QJsonDocument document = QJsonDocument::fromJson(file.readAll());
    if (!document.isObject()) return;
    const QJsonObject values = document.object().value(QStringLiteral("values")).toObject();
    for (auto iterator = values.constBegin(); iterator != values.constEnd(); ++iterator) {
        if (!iterator.value().isString()) continue;
        const auto decoded = unprotect(iterator.value().toString());
        if (decoded) m_values[iterator.key()] = *decoded;
    }
}

void CredentialStore::persist()
{
    QDir().mkpath(QFileInfo(m_path).absolutePath());
    QJsonObject payload;
    for (auto iterator = m_values.constBegin(); iterator != m_values.constEnd(); ++iterator) {
        payload[iterator.key()] = protect(iterator.value());
    }
    QJsonObject root;
    root[QStringLiteral("values")] = payload;

    const QByteArray data = QJsonDocument(root).toJson(QJsonDocument::Compact);
    const QString temporary = m_path + QStringLiteral(".tmp");
    QFile file(temporary);
    if (!file.open(QIODevice::WriteOnly)) {
        CTLog::security().warn(QStringLiteral("写入凭据失败：无法写入临时文件"));
        return;
    }
    file.write(data);
    file.close();
    QFile::remove(m_path);
    if (!QFile::rename(temporary, m_path)) {
        CTLog::security().warn(QStringLiteral("写入凭据失败：无法替换凭据文件"));
        return;
    }
#ifndef Q_OS_WIN
    QFile::setPermissions(m_path, QFile::ReadOwner | QFile::WriteOwner);
#endif
}

QString CredentialStore::protect(const QString& value)
{
#ifdef Q_OS_WIN
    const QByteArray utf8 = value.toUtf8();
    DATA_BLOB input;
    input.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(utf8.constData()));
    input.cbData = static_cast<DWORD>(utf8.size());
    DATA_BLOB output;
    if (CryptProtectData(&input, L"ClearTone", nullptr, nullptr, nullptr, 0, &output)) {
        const QByteArray protectedBytes(reinterpret_cast<const char*>(output.pbData),
            static_cast<qsizetype>(output.cbData));
        LocalFree(output.pbData);
        return QStringLiteral("dpapi:") + QString::fromLatin1(protectedBytes.toBase64());
    }
    CTLog::security().warn(QStringLiteral("凭据加密失败，退回明文存储"));
#endif
    return QStringLiteral("plain:") + QString::fromLatin1(value.toUtf8().toBase64());
}

std::optional<QString> CredentialStore::unprotect(const QString& raw)
{
    if (raw.startsWith(QLatin1String("dpapi:"))) {
#ifdef Q_OS_WIN
        const QByteArray protectedBytes =
            QByteArray::fromBase64(raw.mid(6).toLatin1());
        DATA_BLOB input;
        input.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(protectedBytes.constData()));
        input.cbData = static_cast<DWORD>(protectedBytes.size());
        DATA_BLOB output;
        if (CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr, 0, &output)) {
            const QByteArray plain(reinterpret_cast<const char*>(output.pbData),
                static_cast<qsizetype>(output.cbData));
            LocalFree(output.pbData);
            return QString::fromUtf8(plain);
        }
        CTLog::security().warn(QStringLiteral("凭据解密失败"));
        return std::nullopt;
#else
        return std::nullopt;
#endif
    }
    if (raw.startsWith(QLatin1String("plain:"))) {
        return QString::fromUtf8(QByteArray::fromBase64(raw.mid(6).toLatin1()));
    }
    return std::nullopt;
}

} // namespace ct
