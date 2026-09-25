import Foundation
import Security

/// 凭据存取门面。默认走明文本地文件（`PlaintextCredentialStore`），
/// 可在设置里切回钥匙串。对外 API 与原来完全一致，调用方无需改动。
///
/// 为什么不默认用钥匙串：钥匙串条目按代码签名哈希绑定应用身份，重新构建后签名哈希变化，
/// macOS 会把同一个 App 当成新应用，于是每次启动都弹「输入密码以访问钥匙串」。
public final class KeychainStore: @unchecked Sendable {
    public static let shared = KeychainStore()
    private let service = "com.cleartone.app.keychain"

    /// 内存缓存：无论走哪个后端，每个 key 每次启动至多读一次磁盘/钥匙串
    private var cachedValues: [Key: String?] = [:]
    private var loadedKeys: Set<Key> = []
    private let cacheLock = NSLock()

    private init() {}

    public enum Key: String, Sendable {
        case neteaseCookie = "netease_cookie"
        case neteaseUserID = "netease_user_id"
        case helperAuthToken = "helper_auth_token"
    }

    public enum StorageMode: String, CaseIterable, Sendable {
        /// 明文文件，不再弹密码框
        case plaintextFile
        /// 系统钥匙串
        case keychain

        var displayName: String {
            switch self {
            case .plaintextFile: return "本地文件（不加密）"
            case .keychain: return "系统钥匙串"
            }
        }
    }

    private static let modeDefaultsKey = "credentialStorageMode"

    /// 当前存储方式。缺省为明文文件。
    public static var storageMode: StorageMode {
        get {
            let raw = UserDefaults.standard.string(forKey: modeDefaultsKey)
            return raw.flatMap(StorageMode.init(rawValue:)) ?? .plaintextFile
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeDefaultsKey)
        }
    }

    public func save(_ value: String, for key: Key) throws {
        switch Self.storageMode {
        case .plaintextFile: try PlaintextCredentialStore.shared.save(value, for: key)
        case .keychain: try KeychainBackend.save(value, for: key, service: service)
        }
        setCachedValue(value, for: key)
    }

    public func load(for key: Key) throws -> String? {
        if let cached = cachedValue(for: key) { return cached }
        let value = try readUncached(key)
        // 只有"确实不存在"才缓存 nil；读取失败必须抛出，不能让用户看起来像未登录
        setCachedValue(value, for: key)
        return value
    }

    public func delete(for key: Key) throws {
        switch Self.storageMode {
        case .plaintextFile: try PlaintextCredentialStore.shared.delete(for: key)
        case .keychain: try KeychainBackend.delete(for: key, service: service)
        }
        invalidate(key)
    }

    public func clearAll() throws {
        for key in [Key.neteaseCookie, .neteaseUserID, .helperAuthToken] {
            try? delete(for: key)
        }
    }

    /// 只清空内存缓存，不删除任何已保存的凭据。
    /// 切换存储方式时用它，让下次读取按新位置重新加载（并触发钥匙串 → 明文文件的迁移）。
    public func invalidateCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedValues.removeAll()
        loadedKeys.removeAll()
    }

    /// 明文模式下本地文件没有该 key 时，从钥匙串迁移过来并删除钥匙串条目，
    /// 这样用户不需要重新登录，也不会再看到密码弹框。
    private func readUncached(_ key: Key) throws -> String? {
        if Self.storageMode == .plaintextFile {
            if let local = try PlaintextCredentialStore.shared.load(for: key) { return local }
            // try? 会把 String? 拍平成 String?，这里再解包一层
            let legacy: String? = (try? KeychainBackend.load(for: key, service: service)) ?? nil
            if let legacy {
                try? PlaintextCredentialStore.shared.save(legacy, for: key)
                try? KeychainBackend.delete(for: key, service: service)
                return legacy
            }
            return nil
        }
        return try KeychainBackend.load(for: key, service: service)
    }

    // MARK: - 缓存

    private func cachedValue(for key: Key) -> String?? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard loadedKeys.contains(key) else { return nil }
        return cachedValues[key]
    }

    private func setCachedValue(_ value: String?, for key: Key) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedValues[key] = value
        loadedKeys.insert(key)
    }

    private func invalidate(_ key: Key) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedValues[key] = nil
        loadedKeys.remove(key)
    }
}

/// 钥匙串后端实现，保持原有 SecItem 语义
private enum KeychainBackend {
    static func save(_ value: String, for key: KeychainStore.Key, service: String) throws {
        guard let data = value.data(using: .utf8) else { throw MusicError.unknown("Keychain 编码失败") }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw MusicError.unknown("Keychain 保存失败: \(addStatus)") }
        } else if status != errSecSuccess {
            throw MusicError.unknown("Keychain 更新失败: \(status)")
        }
    }

    static func load(for key: KeychainStore.Key, service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        if status == errSecItemNotFound { return nil }
        throw MusicError.unknown("Keychain 读取失败: \(status)")
    }

    static func delete(for key: KeychainStore.Key, service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MusicError.unknown("Keychain 删除失败: \(status)")
        }
    }
}
