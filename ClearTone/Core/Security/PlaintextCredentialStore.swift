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
final class PlaintextCredentialStore: CredentialBackend, @unchecked Sendable {
    static let shared = PlaintextCredentialStore()

    typealias Key = KeychainStore.Key

    private let lock = NSLock()
    /// nil = 尚未从磁盘读过
    private var cache: [String: String]?

    private let fileURL: URL

    private init() {
        // 必须走 `PersistenceStore.storageRoot`，不能自己拼 Application Support：
        // 后者**不认 `CLEARTONE_TEST_STORAGE_DIR`**，于是 `run-tests.sh` 声称的
        // 「一个环境变量管住全部持久化」对凭据文件是假的 —— 任何调用
        // `KeychainStore.save/delete` 的测试都会改写开发者真实的 credentials.json
        // （在 `storageMode == .keychain` 的机器上还会去碰真实钥匙串）。
        // 生产路径与原来逐字节相同（storageRoot 就是 `…/Application Support/ClearTone`）。
        let dir = PersistenceStore.storageRoot
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
        // 自己建 0600 的临时文件再 rename，不用 `Data.write(.atomic)`。
        //
        // 实测：Foundation 的 `.atomic` 在 macOS 上落盘是 **0644**（它按 umask 建临时
        // 文件再 rename），所以原来那句 `try? setAttributes(0600)` 是唯一的权限防线 ——
        // 而它是 `try?`，失败静默。一旦失败，明文凭据就**永久**停在 0644，
        // 界面上、日志里都看不出任何异常。0600 是这里仅有的防线，必须确定性地拿到。
        let tmp = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]
        ) else {
            throw MusicError.unknown("本地凭据临时文件创建失败")
        }
        // 同目录内的 rename(2) 是原子的，且不换 inode —— 0600 跟着文件走
        guard rename(tmp.path, fileURL.path) == 0 else {
            let message = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tmp)
            throw MusicError.unknown("本地凭据写入失败：\(message)")
        }
        cache = values
    }

    private func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}
