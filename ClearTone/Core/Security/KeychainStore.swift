import Foundation
import Security

/// 凭据后端。抽成协议是为了让**迁移逻辑**能被离线单测覆盖：
/// 这条路径原本只能靠真实钥匙串验证，于是「删干净了吗」「迁移失败会不会丢凭据」
/// 这类问题在 475 项全绿的情况下依然是零覆盖。
protocol CredentialBackend: Sendable {
    func save(_ value: String, for key: KeychainStore.Key) throws
    func load(for key: KeychainStore.Key) throws -> String?
    func delete(for key: KeychainStore.Key) throws
}

/// 凭据存取门面。默认走明文本地文件（`PlaintextCredentialStore`），
/// 可在设置里切回钥匙串。对外 API 与原来完全一致，调用方无需改动。
///
/// 为什么不默认用钥匙串：钥匙串条目按代码签名哈希绑定应用身份，重新构建后签名哈希变化，
/// macOS 会把同一个 App 当成新应用，于是每次启动都弹「输入密码以访问钥匙串」。
public final class KeychainStore: @unchecked Sendable {
    public static let shared = KeychainStore()
    private static let service = "com.cleartone.app.keychain"

    private let plaintextBackend: any CredentialBackend
    private let keychainBackend: any CredentialBackend

    /// 内存缓存：无论走哪个后端，每个 key 每次启动至多读一次磁盘/钥匙串
    private var cachedValues: [Key: String?] = [:]
    private var loadedKeys: Set<Key> = []
    private let cacheLock = NSLock()

    private init() {
        self.plaintextBackend = PlaintextCredentialStore.shared
        self.keychainBackend = KeychainBackend(service: Self.service)
    }

    /// 测试注入点：用内存后端替换真实钥匙串/文件，验证双后端删除与迁移语义。
    /// 生产代码只走 `shared`。
    init(plaintextBackend: any CredentialBackend, keychainBackend: any CredentialBackend) {
        self.plaintextBackend = plaintextBackend
        self.keychainBackend = keychainBackend
    }

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

    /// 当前存储方式。缺省：iOS 钥匙串，macOS 明文文件。
    public static var storageMode: StorageMode {
        get {
            // 显式存过的值必须算数。iOS 分支原先**无条件**返回 .keychain，
            // 于是 setter 是死写：用户在设置里选了也无效，且老构建写在
            // credentials.json 里的凭据既读不到也清不掉（现在靠双向迁移补上）。
            if let raw = UserDefaults.standard.string(forKey: modeDefaultsKey),
               let mode = StorageMode(rawValue: raw) {
                return mode
            }
            #if os(iOS)
            // 单 App 的默认钥匙串不需要 Keychain Sharing capability。
            return .keychain
            #else
            return .plaintextFile
            #endif
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeDefaultsKey)
        }
    }

    public func save(_ value: String, for key: Key) throws {
        try writeActive(value, for: key)
        setCachedValue(value, for: key)
    }

    public func load(for key: Key) throws -> String? {
        if let cached = cachedValue(for: key) { return cached }
        let value = try readUncached(key)
        // 只有"确实不存在"才缓存 nil；读取失败必须抛出，不能让用户看起来像未登录
        setCachedValue(value, for: key)
        return value
    }

    /// 删除**两个**后端里该 key。
    ///
    /// 原先只删 `Self.storageMode` 那一边，于是「我已经退出登录了」与磁盘状态不一致：
    /// 本地文件模式下登出，keychain 里那份（或反过来）**永久残留**。
    /// 当前后端失败必须抛出（否则调用方会以为删干净了）；另一边尽力而为 ——
    /// 钥匙串在锁定/签名变化时可能拒绝，但没有那一边也不该让登出整体失败。
    ///
    /// 代价：本地文件模式下登录/登出会去碰一次钥匙串。这可以接受 ——
    /// `.plaintextFile` 的存在理由是**启动与读取**不弹密码框，而不是永不触碰钥匙串。
    public func delete(for key: Key) throws {
        try writeActive(nil, for: key)
        try? writeInactive(nil, for: key)
        invalidate(key)
    }

    public func clearAll() throws {
        for key in [Key.neteaseCookie, .neteaseUserID, .helperAuthToken] {
            try? delete(for: key)
        }
    }

    /// 只清空内存缓存，不删除任何已保存的凭据。
    /// 切换存储方式时用它，让下次读取按新位置重新加载（并触发双向迁移）。
    public func invalidateCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedValues.removeAll()
        loadedKeys.removeAll()
    }

    // MARK: - 双后端迁移

    /// 当前后端没有该 key、而**另一个**后端有：把值迁到当前后端，
    /// **写成功之后**才删源副本。
    ///
    /// 为什么必须双向：老版本把凭据写在明文文件里，用户在设置里切到钥匙串后，
    /// 只读钥匙串会得到 nil —— 界面显示未登录，而 `credentials.json` 里的 `MUSIC_U`
    /// 原封不动留在盘上（看起来被登出 + 明文残留，两头都不对）。
    /// 反过来（钥匙串 → 文件）是原本就有的方向，但原先用 `try? save` 配**无条件** delete：
    /// 保存失败也照样删源，凭据彻底丢失、被迫重新扫码。
    private func readUncached(_ key: Key) throws -> String? {
        // 当前后端必须抛错（文件损坏 / 钥匙串拒绝都不能伪装成「未登录」）；
        // 另一侧是 best-effort —— 它坏了不该挡住正常的读取。
        if let primary = try readActive(key) { return primary }
        let legacy: String? = (try? readInactive(key)) ?? nil
        guard let legacy else { return nil }
        do {
            try writeActive(legacy, for: key)
        } catch {
            // 迁移失败：保留源副本，下次再试。绝不能为了「清掉残留」删掉唯一的副本。
            CTLog.security.error("凭据迁移失败，保留原副本: \(CTLog.sanitize(error.localizedDescription))")
            return legacy
        }
        try? writeInactive(nil, for: key)
        return legacy
    }

    // MARK: - 后端分派

    private var active: any CredentialBackend {
        Self.storageMode == .plaintextFile ? plaintextBackend : keychainBackend
    }

    private var inactive: any CredentialBackend {
        Self.storageMode == .plaintextFile ? keychainBackend : plaintextBackend
    }

    private func writeActive(_ value: String?, for key: Key) throws {
        if let value { try active.save(value, for: key) } else { try active.delete(for: key) }
    }

    private func writeInactive(_ value: String?, for key: Key) throws {
        if let value { try inactive.save(value, for: key) } else { try inactive.delete(for: key) }
    }

    private func readActive(_ key: Key) throws -> String? {
        try active.load(for: key)
    }

    private func readInactive(_ key: Key) throws -> String? {
        try inactive.load(for: key)
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

/// 钥匙串后端实现，保持原有 SecItem 语义。
///
/// **单测隔离**：钥匙串不在文件系统里，没有路径可以像 `CLEARTONE_TEST_STORAGE_DIR`
/// 那样重定向。`delete` 现在是**双后端**操作，若不旁路，跑一次测试就可能把开发者
/// 本机的 `netease_cookie` 条目真删掉。所以只要那个环境变量在，这里一律假装
/// 「钥匙串里什么都没有，也删不进东西」。
private struct KeychainBackend: CredentialBackend {
    let service: String

    private static var isolatedFromTests: Bool {
        (ProcessInfo.processInfo.environment["CLEARTONE_TEST_STORAGE_DIR"] ?? "").isEmpty == false
    }

    func save(_ value: String, for key: KeychainStore.Key) throws {
        guard !Self.isolatedFromTests else { return }
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

    func load(for key: KeychainStore.Key) throws -> String? {
        guard !Self.isolatedFromTests else { return nil }
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

    func delete(for key: KeychainStore.Key) throws {
        guard !Self.isolatedFromTests else { return }
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
