#pragma once

#include <QHash>
#include <QString>

#include <optional>

namespace ct {

enum class CredentialKey {
    NeteaseCookie,
    NeteaseUserID,
    HelperAuthToken,
};

class CredentialStore {
public:
    static CredentialStore& shared();

    explicit CredentialStore(QString path = {});

    std::optional<QString> load(CredentialKey key);
    void save(const QString& value, CredentialKey key);
    void remove(CredentialKey key);
    bool has(CredentialKey key);

    static QString storageRoot();

private:
    static QString nameOf(CredentialKey key);
    void ensureLoaded();
    void persist();
    static QString protect(const QString& value);
    static std::optional<QString> unprotect(const QString& raw);

    QString m_path;
    QHash<QString, QString> m_values;
    bool m_loaded = false;
};

} // namespace ct
