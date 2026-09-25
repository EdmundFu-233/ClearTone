import Foundation

/// 明文本地凭据存储。
///
/// 存在的理由：钥匙串条目通过代码签名哈希绑定应用身份，重新构建（签名哈希变化）后
/// macOS 会把同一个 App 视为新应用，于是每次启动都弹「输入密码以访问钥匙串」。
/// 对于自用播放器，把 Cookie 明文存在本地文件更省事。
///
/// 安全取舍：
/// - 文件权限 600，仅当前用户可读
/// - 排除出 Time Machine / iCloud 备份，避免凭据被同步到其他设备
/// - 目录建议开启 FileVault（现代 macOS 默认开启），这样磁盘上的明文同样是加密的
final class PlaintextCredentialStore: @unchecked Sendable {
    static let shared = PlaintextCredentialStore()

    typealias Key = KeychainStore.Key

    private let lock = NSLock()
    /// nil = 尚未从磁盘读过
    private var cache: [String: String]?

    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("ClearTone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("credentials.json")
        excludeFromBackup(dir)
    }

    var path: String { fileURL.path }

    // MARK: - 读写

    func save(_ value: String, for key: Key) throws {
        lock.lock()
        defer { lock.unlock() }
        var all = try loadUnlocked()
        all[key.rawValue] = value
        try writeUnlocked(all)
    }

    func load(for key: Key) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()[key.rawValue]
    }

    func delete(for key: Key) throws {
        lock.lock()
        defer { lock.unlock() }
        var all = try loadUnlocked()
        all.removeValue(forKey: key.rawValue)
        try writeUnlocked(all)
    }

    func clearAll() throws {
        lock.lock()
        defer { lock.unlock() }
        try writeUnlocked([:])
    }

    // MARK: - Private

    private func loadUnlocked() throws -> [String: String] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = [:]
            return [:]
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([String: String].self, from: data)
            cache = decoded
            return decoded
        } catch {
            // 文件损坏时不能当成"未登录"静默吞掉，否则用户会莫名掉登录
            throw MusicError.unknown("本地凭据文件损坏：\(error.localizedDescription)")
        }
    }

    private func writeUnlocked(_ values: [String: String]) throws {
        let data = try JSONEncoder().encode(values)
        try data.write(to: fileURL, options: [.atomic])
        // 原子写入会重建文件，重新收紧权限
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        cache = values
    }

    private func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}
