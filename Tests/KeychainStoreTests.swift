import XCTest

/// 凭据存储：双后端删除、双向迁移、文件权限与**测试隔离**。
///
/// 三条都是「475 项全绿也照样漏掉」的东西：
/// 1. `delete` 原先只删当前 `storageMode` 那一边 —— 「我已经退出登录了」与磁盘状态不一致。
/// 2. 迁移用 `try? save` 配**无条件** delete —— 保存失败也会把唯一的副本删掉。
/// 3. `PlaintextCredentialStore` 原先不认 `CLEARTONE_TEST_STORAGE_DIR` ——
///    `run-tests.sh` 声称的「一个环境变量管住全部持久化」对凭据文件是假的。
@MainActor
final class KeychainStoreTests: XCTestCase {

    // MARK: - 桩后端

    /// 内存后端：不碰真实钥匙串，也不落盘。
    private final class MemoryBackend: CredentialBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [KeychainStore.Key: String] = [:]
        private(set) var saves = 0
        private(set) var deletes = 0
        /// 置为 true 后 save 抛错，用来验证「目标写失败不能删源」
        var failSaves = false
        /// 置为 true 后 delete 抛错，用来验证「主动后端失败必须抛出去」
        var failDeletes = false

        func save(_ value: String, for key: KeychainStore.Key) throws {
            lock.lock(); defer { lock.unlock() }
            if failSaves { throw MusicError.unknown("桩保存失败") }
            saves += 1
            values[key] = value
        }

        func load(for key: KeychainStore.Key) throws -> String? {
            lock.lock(); defer { lock.unlock() }
            return values[key]
        }

        func delete(for key: KeychainStore.Key) throws {
            lock.lock(); defer { lock.unlock() }
            if failDeletes { throw MusicError.unknown("桩删除失败") }
            deletes += 1
            values.removeValue(forKey: key)
        }

        var all: [KeychainStore.Key: String] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    private var savedMode: KeychainStore.StorageMode = .plaintextFile

    override func setUp() async throws {
        savedMode = KeychainStore.storageMode
        // 每条用例都从明文模式起跑，不依赖「测试进程 UserDefaults 恰好是空的」
        KeychainStore.storageMode = .plaintextFile
        // 删除墓碑是跨用例的 UserDefaults 状态，逐条清掉，避免互相影响
        UserDefaults.standard.removeObject(forKey: KeychainStore.deletedMarksDefaultsKey)
    }

    override func tearDown() async throws {
        KeychainStore.storageMode = savedMode
        UserDefaults.standard.removeObject(forKey: KeychainStore.deletedMarksDefaultsKey)
    }

    private func makeStore(
        plaintext: MemoryBackend = MemoryBackend(),
        keychain: MemoryBackend = MemoryBackend()
    ) -> (KeychainStore, MemoryBackend, MemoryBackend) {
        (KeychainStore(plaintextBackend: plaintext, keychainBackend: keychain), plaintext, keychain)
    }

    // MARK: - 双后端删除

    /// 登出必须**两个**后端都清。原先只删当前模式那一边。
    func testDeleteClearsBothBackends() throws {
        KeychainStore.storageMode = .plaintextFile
        let (store, plaintext, keychain) = makeStore()

        // 两边都预先有值：模拟「老版本写在钥匙串里，现在用的是本地文件」
        try plaintext.save("cookie-from-file", for: .neteaseCookie)
        try keychain.save("cookie-from-keychain", for: .neteaseCookie)

        try store.delete(for: .neteaseCookie)

        XCTAssertNil(try plaintext.load(for: .neteaseCookie), "本地文件那份必须删掉")
        XCTAssertNil(try keychain.load(for: .neteaseCookie), "钥匙串那份也必须删掉 —— 只删一边就是明文/凭据残留")
        XCTAssertNil(try store.load(for: .neteaseCookie))
    }

    func testDeleteClearsBothBackendsInKeychainMode() throws {
        KeychainStore.storageMode = .keychain
        let (store, plaintext, keychain) = makeStore()

        try plaintext.save("cookie-from-file", for: .neteaseUserID)
        try keychain.save("cookie-from-keychain", for: .neteaseUserID)

        try store.delete(for: .neteaseUserID)

        XCTAssertNil(try plaintext.load(for: .neteaseUserID))
        XCTAssertNil(try keychain.load(for: .neteaseUserID))
    }

    /// 主动后端删除失败必须抛出去 —— 否则调用方（`logout()` 的 defer 是 `try?`）
    /// 与上层都会以为删干净了，而凭据其实还在。
    func testDeletePropagatesActiveBackendFailure() throws {
        let plaintext = MemoryBackend()
        let keychain = MemoryBackend()
        plaintext.failDeletes = true
        let store = KeychainStore(plaintextBackend: plaintext, keychainBackend: keychain)
        try keychain.save("still-here", for: .neteaseCookie)

        XCTAssertThrowsError(try store.delete(for: .neteaseCookie))

        XCTAssertEqual(
            try keychain.load(for: .neteaseCookie), "still-here",
            "主动后端删除失败时不该继续去删另一侧"
        )
    }

    /// 另一侧删除失败时，残留值不得在下次 load 时被迁回来（否则等于没登出）。
    ///
    /// 场景：本地文件模式，钥匙串里有一份旧副本，钥匙串删除被拒（锁定/签名变化）。
    /// `delete` 吞掉另一侧的错误，若无墓碑，第二次 `load` 会把那份旧 Cookie
    /// 重新迁进文件里 ——「退出登录」在重启后又变回已登录。
    func testDeleteDoesNotResurrectFromInactiveBackend() throws {
        KeychainStore.storageMode = .plaintextFile
        let plaintext = MemoryBackend()
        let keychain = MemoryBackend()
        let store = KeychainStore(plaintextBackend: plaintext, keychainBackend: keychain)

        try keychain.save("legacy-cookie", for: .neteaseCookie)
        keychain.failDeletes = true
        try plaintext.save("current", for: .neteaseCookie)

        try store.delete(for: .neteaseCookie)

        // 另起一个 store（模拟重启后缓存为空、重新读盘），残留值不得复活
        let restarted = KeychainStore(plaintextBackend: plaintext, keychainBackend: keychain)
        XCTAssertNil(
            try restarted.load(for: .neteaseCookie),
            "显式删除后，另一侧删不掉的残留不得被迁回（等于没登出）"
        )

        // 重新登录：save 必须清掉墓碑，新值读得出来
        try store.save("new-cookie", for: .neteaseCookie)
        let restartedAgain = KeychainStore(plaintextBackend: plaintext, keychainBackend: keychain)
        XCTAssertEqual(try restartedAgain.load(for: .neteaseCookie), "new-cookie")
    }

    // MARK: - 双向迁移

    /// 本地文件模式下，钥匙串里有值 → 迁到文件里，并**删掉源副本**。
    func testMigratesKeychainValueIntoPlaintextAndRemovesSource() throws {
        KeychainStore.storageMode = .plaintextFile
        let (store, plaintext, keychain) = makeStore()
        try keychain.save("legacy-cookie", for: .neteaseCookie)

        let loaded = try store.load(for: .neteaseCookie)

        XCTAssertEqual(loaded, "legacy-cookie", "切到本地文件后不该被登出")
        XCTAssertEqual(try plaintext.load(for: .neteaseCookie), "legacy-cookie", "值必须迁过来")
        XCTAssertNil(try keychain.load(for: .neteaseCookie), "迁移成功后源副本要清掉")
    }

    /// 反方向：钥匙串模式下，本地文件里有值 → 迁到钥匙串里。
    ///
    /// 这条是 P0：老版本把凭据写在 `credentials.json`，用户切到钥匙串后
    /// 原先只读钥匙串，于是**界面显示未登录，而明文 Cookie 照旧留在盘上**。
    func testMigratesPlaintextValueIntoKeychainAndRemovesSource() throws {
        KeychainStore.storageMode = .keychain
        let (store, plaintext, keychain) = makeStore()
        try plaintext.save("file-cookie", for: .neteaseCookie)

        let loaded = try store.load(for: .neteaseCookie)

        XCTAssertEqual(loaded, "file-cookie", "切到钥匙串后不该被登出")
        XCTAssertEqual(try keychain.load(for: .neteaseCookie), "file-cookie")
        XCTAssertNil(try plaintext.load(for: .neteaseCookie), "明文那份必须清掉，否则等于没迁")
    }

    /// 迁移的**顺序**：先写目标、成功后才删源。
    /// 原先 `try? save` + 无条件 delete —— 保存失败也会把唯一的副本删掉，
    /// 凭据彻底丢失，用户被迫重新扫码。
    func testMigrationKeepsSourceWhenTargetSaveFails() throws {
        KeychainStore.storageMode = .keychain
        let plaintext = MemoryBackend()
        let keychain = MemoryBackend()
        keychain.failSaves = true
        let store = KeychainStore(plaintextBackend: plaintext, keychainBackend: keychain)
        try plaintext.save("only-copy", for: .neteaseCookie)

        let loaded = try store.load(for: .neteaseCookie)

        XCTAssertEqual(loaded, "only-copy", "迁移失败时仍要能把值读出来")
        XCTAssertEqual(
            try plaintext.load(for: .neteaseCookie), "only-copy",
            "目标写失败绝不能删源 —— 那是唯一的副本，删了就要重新扫码"
        )
        XCTAssertNil(try keychain.load(for: .neteaseCookie))
    }

    /// 两边都有值时以**当前模式**为准，不做多余迁移
    func testActiveBackendWinsWithoutMigration() throws {
        KeychainStore.storageMode = .plaintextFile
        let (store, plaintext, keychain) = makeStore()
        try plaintext.save("current", for: .neteaseCookie)
        try keychain.save("other", for: .neteaseCookie)

        XCTAssertEqual(try store.load(for: .neteaseCookie), "current")
        XCTAssertEqual(try keychain.load(for: .neteaseCookie), "other", "当前侧有值时不该动另一侧")
    }

    // MARK: - 明文文件：权限与测试隔离

    /// `CLEARTONE_TEST_STORAGE_DIR` 必须对凭据文件生效。
    ///
    /// 原先它自己拼 Application Support，于是 `run-tests.sh` 的持久化隔离对它是假的 ——
    /// 任何调用 `save/delete` 的测试都会改写开发者真实的 credentials.json。
    func testCredentialFileLivesUnderStorageRoot() {
        let path = PlaintextCredentialStore.shared.path
        let root = PersistenceStore.storageRoot.path
        XCTAssertTrue(
            path.hasPrefix(root),
            "凭据文件必须落在持久化根目录下（这样环境变量才管得住）：\(path) vs \(root)"
        )
        XCTAssertTrue(path.hasSuffix("credentials.json"))
    }

    /// 0600 是明文凭据**唯一**的权限防线。
    ///
    /// `Data.write(.atomic)` 实测落盘是 0644（按 umask 建临时文件再 rename），
    /// 原先靠一句 `try? setAttributes` 兜底 —— 失败静默、且写入到 chmod 之间
    /// 有一个 0644 的窗口。现在改成自建 0600 临时文件再 rename。
    func testCredentialFileIsOwnerOnlyAfterWrite() throws {
        let key = KeychainStore.Key.helperAuthToken
        try? PlaintextCredentialStore.shared.delete(for: key)
        let store = KeychainStore(
            plaintextBackend: PlaintextCredentialStore.shared,
            keychainBackend: MemoryBackend()
        )
        defer { try? store.delete(for: key) }

        try store.save("secret", for: key)
        let attrs = try FileManager.default.attributesOfItem(
            atPath: PlaintextCredentialStore.shared.path
        )
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uintValue
        XCTAssertEqual(mode, 0o600, "凭据文件必须是 0600，写入后不该有 0644 窗口或残留")

        try store.delete(for: key)
        XCTAssertNil(try PlaintextCredentialStore.shared.load(for: key))
    }

    /// 明文后端 round-trip：写进去读得出来，删了读不到
    func testPlaintextBackendRoundTrip() throws {
        let backend = PlaintextCredentialStore.shared
        let key = KeychainStore.Key.neteaseUserID
        defer { try? backend.delete(for: key) }

        try backend.delete(for: key)
        XCTAssertNil(try backend.load(for: key))
        try backend.save("86080189", for: key)
        XCTAssertEqual(try backend.load(for: key), "86080189")
        try backend.delete(for: key)
        XCTAssertNil(try backend.load(for: key))
    }
}
