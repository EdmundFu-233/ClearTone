import Foundation
import Security

/// Keychain 安全存储，用于保存网易云 Cookie / Token
public final class KeychainStore: @unchecked Sendable {
    public static let shared = KeychainStore()
    private let service = "com.cleartone.app.keychain"

    /// 内存缓存：钥匙串读取可能被 macOS 拦截并弹出"输入密码"授权框，
    /// 原实现每次 API 请求都要读一次钥匙串，导致弹窗频繁出现。
    /// 缓存后每个 key 每次启动至多从钥匙串读取一次。
    private var cachedValues: [Key: String?] = [:]
    private var loadedKeys: Set<Key> = []
    private let cacheLock = NSLock()

    private init() {}

    public enum Key: String, Sendable {
        case neteaseCookie = "netease_cookie"
        case neteaseUserID = "netease_user_id"
        case helperAuthToken = "helper_auth_token"
    }

    public func save(_ value: String, for key: Key) throws {
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
        setCachedValue(value, for: key)
    }

    public func load(for key: Key) throws -> String? {
        if let cached = cachedValue(for: key) { return cached }

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
            let value = String(data: data, encoding: .utf8)
            setCachedValue(value, for: key)
            return value
        }
        if status == errSecItemNotFound {
            // 只有“确实不存在”才缓存 nil；瞬时失败不能让用户看起来像未登录
            setCachedValue(nil, for: key)
            return nil
        }
        throw MusicError.unknown("Keychain 读取失败: \(status)")
    }

    public func delete(for key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MusicError.unknown("Keychain 删除失败: \(status)")
        }
        invalidate(key)
    }

    public func clearAll() throws {
        for key in [Key.neteaseCookie, .neteaseUserID, .helperAuthToken] {
            try? delete(for: key)
        }
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