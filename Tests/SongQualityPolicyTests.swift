import XCTest
import Foundation

/// 音质决策：默认吃缓存 vs 单曲点名走网易源，以及无损码率的反算。
@MainActor
final class SongQualityPolicyTests: XCTestCase {

    // MARK: 纯规则

    func testOverrideWinsOverGlobal() {
        XCTAssertEqual(
            SongQualityPolicy.effectiveLevel(override: .lossless, global: .exhigh), .lossless
        )
        XCTAssertEqual(
            SongQualityPolicy.effectiveLevel(override: nil, global: .exhigh), .exhigh
        )
    }

    func testCacheIsUsedOnlyWithoutOverride() {
        XCTAssertTrue(SongQualityPolicy.useLocalCache(hasOverride: false), "默认必须吃缓存")
        XCTAssertFalse(SongQualityPolicy.useLocalCache(hasOverride: true), "点名音质后必须走网易源")
    }

    /// 有覆盖时不写缓存：128k OPUS 对点名无损的歌是降级，
    /// 而且下次播放有覆盖也不会用到这份缓存
    func testNoCacheWriteWhenOverridden() {
        XCTAssertFalse(SongQualityPolicy.shouldWriteCache(hasOverride: true, isPreview: false))
        XCTAssertFalse(SongQualityPolicy.shouldWriteCache(hasOverride: false, isPreview: true))
        XCTAssertTrue(SongQualityPolicy.shouldWriteCache(hasOverride: false, isPreview: false))
    }

    func testSelectableLevelsExcludeUnknownPlaceholder() {
        XCTAssertFalse(SongQualityPolicy.selectableLevels.contains(.unknown))
        XCTAssertEqual(SongQualityPolicy.selectableLevels.count, 5)
        XCTAssertTrue(SongQualityPolicy.selectableLevels.contains(.lossless))
        XCTAssertTrue(SongQualityPolicy.selectableLevels.contains(.hires))
    }

    // MARK: VIP 决定的默认档位

    /// 有 VIP 时默认无损，没有则保持极高。
    func testDefaultLevelDependsOnVIP() {
        XCTAssertEqual(SongQualityPolicy.defaultLevel(isVIP: true), .lossless)
        XCTAssertEqual(SongQualityPolicy.defaultLevel(isVIP: false), .exhigh)
    }

    /// 「自动」才看 VIP；用户显式选过的档位**绝不因为 VIP 变化而改动**。
    ///
    /// 后半句是关键：如果 VIP 登录/退出时改掉显式选择，
    /// 用户设好的「极高」会无声地变成「无损」。
    func testAutoResolvesByVIPButExplicitChoiceIsUntouched() {
        XCTAssertEqual(
            SongQualityPolicy.effectiveGlobalLevel(preference: .unknown, isVIP: true), .lossless
        )
        XCTAssertEqual(
            SongQualityPolicy.effectiveGlobalLevel(preference: .unknown, isVIP: false), .exhigh
        )
        for explicit in SongQualityPolicy.selectableLevels {
            XCTAssertEqual(
                SongQualityPolicy.effectiveGlobalLevel(preference: explicit, isVIP: true), explicit
            )
            XCTAssertEqual(
                SongQualityPolicy.effectiveGlobalLevel(preference: explicit, isVIP: false), explicit
            )
        }
    }

    /// 「自动」用的哨兵值不能出现在可选列表里，否则设置页会多出一个
    /// 叫「未知」的选项（`selectableLevels` 已经过滤了它）。
    func testAutoSentinelIsTheUnknownPlaceholder() {
        XCTAssertEqual(SongQualityPolicy.autoLevel, .unknown)
        XCTAssertFalse(SongQualityPolicy.selectableLevels.contains(SongQualityPolicy.autoLevel))
    }

    /// 退登后不能还在按无损请求 —— 白白拿 403。
    /// VIP 解析的结果必须每次都跟着 isVIP 变。
    func testGlobalLevelFollowsVIPChangeBackAndForth() {
        let preference = SongQualityPolicy.autoLevel
        XCTAssertEqual(SongQualityPolicy.effectiveGlobalLevel(preference: preference, isVIP: true), .lossless)
        XCTAssertEqual(SongQualityPolicy.effectiveGlobalLevel(preference: preference, isVIP: false), .exhigh)
    }

    // MARK: 无损码率反算（FLAC 的 br 常为 0，只给 size）

    func testDerivedBitrateFromSizeAndDuration() throws {
        // 30 秒、约 3.9MB 的 FLAC ≈ 1050kbps
        let kbps = try XCTUnwrap(SongQualityPolicy.derivedBitrateKbps(sizeBytes: 3_900_000, duration: 30))
        XCTAssertEqual(kbps, 1040, accuracy: 5)
    }

    func testDerivedBitrateReturnsNilWhenDataInsufficient() {
        XCTAssertNil(SongQualityPolicy.derivedBitrateKbps(sizeBytes: nil, duration: 30))
        XCTAssertNil(SongQualityPolicy.derivedBitrateKbps(sizeBytes: 0, duration: 30))
        XCTAssertNil(SongQualityPolicy.derivedBitrateKbps(sizeBytes: 3_900_000, duration: 0))
        XCTAssertNil(SongQualityPolicy.derivedBitrateKbps(sizeBytes: 3_900_000, duration: 0.5))
    }

    // MARK: 控制器上的覆盖读写

    /// 持久化隔离由 `scripts/run-tests.sh` 统一 `export CLEARTONE_TEST_STORAGE_DIR` 完成。
    ///
    /// 原来这个类各自 `setenv` 了一个**不同的**目录，而
    /// `PersistenceStore.storageURL` 是 `private let`（只求值一次）——
    /// 于是「谁先跑谁赢」，另一个类的 setenv 静默无效。
    /// `DemoAudioGeneratorTests` 当时压根不隔离，直接删改开发者真实 App 目录下的
    /// tone_440.wav。现在所有持久化都挂在 `PersistenceStore.storageRoot` 上，
    /// 一个环境变量即可全部隔离。
    private static let storageIsolated: Void = {
        XCTAssertNotNil(
            getenv("CLEARTONE_TEST_STORAGE_DIR"),
            "请通过 ./scripts/run-tests.sh 运行；直接跑 xctest 会写到真实用户目录"
        )
        return ()
    }()

    /// 覆盖表的增删改查 + 有效音质。结束时清掉，避免把测试歌名写进用户偏好
    func testOverrideLifecycleOnController() {
        _ = Self.storageIsolated
        let player = PlayerController.shared
        let songID = "test-quality-override-\(UUID().uuidString)"
        defer { player.setQualityOverride(nil, for: songID) }

        player.setRequestedQuality(.exhigh)
        XCTAssertNil(player.qualityOverride(for: songID))
        XCTAssertEqual(player.effectiveQuality(for: songID), .exhigh)

        player.setQualityOverride(.lossless, for: songID)
        XCTAssertEqual(player.qualityOverride(for: songID), .lossless)
        XCTAssertEqual(player.effectiveQuality(for: songID), .lossless)
        XCTAssertTrue(player.songQualityOverrides.contains { $0.songID == songID })

        // 重复设置同一首歌 = 换档，不应留下两条
        player.setQualityOverride(.hires, for: songID)
        XCTAssertEqual(player.qualityOverride(for: songID), .hires)
        XCTAssertEqual(player.songQualityOverrides.filter { $0.songID == songID }.count, 1)

        // `.unknown` 是内部占位，不该被当成用户选择存下来
        player.setQualityOverride(.unknown, for: songID)
        XCTAssertNil(player.qualityOverride(for: songID), ".unknown 应当等价于「跟随全局」")
        XCTAssertEqual(player.effectiveQuality(for: songID), .exhigh)

        player.setQualityOverride(.higher, for: songID)
        XCTAssertNotNil(player.qualityOverride(for: songID))
        player.setQualityOverride(nil, for: songID)
        XCTAssertNil(player.qualityOverride(for: songID))
        XCTAssertFalse(player.songQualityOverrides.contains { $0.songID == songID })
    }

    /// 全局音质变更不得覆盖某一首已经点名的音质
    func testGlobalChangeDoesNotOverrideSongOverride() {
        _ = Self.storageIsolated
        let player = PlayerController.shared
        let songID = "test-quality-global-\(UUID().uuidString)"
        let originalGlobal = player.requestedQuality
        defer {
            player.setQualityOverride(nil, for: songID)
            player.setRequestedQuality(originalGlobal)
        }

        player.setQualityOverride(.lossless, for: songID)
        player.setRequestedQuality(.standard)
        XCTAssertEqual(player.effectiveQuality(for: songID), .lossless, "单曲覆盖必须压过全局设置")
        XCTAssertEqual(player.effectiveQuality(for: "some-other-song"), .standard)
    }

    /// 覆盖表容量上限：只保留最近改动的 N 条
    func testOverrideTableIsTrimmed() {
        _ = Self.storageIsolated
        let player = PlayerController.shared
        let ids = (0..<260).map { "trim-\($0)-\(UUID().uuidString)" }
        defer { ids.forEach { player.setQualityOverride(nil, for: $0) } }

        for id in ids { player.setQualityOverride(.lossless, for: id) }
        XCTAssertLessThanOrEqual(player.songQualityOverrides.count, 200)
        // 最近改动的还在
        XCTAssertNotNil(player.qualityOverride(for: ids[259]))
        // 最早那批已被淘汰
        XCTAssertNil(player.qualityOverride(for: ids[0]))
    }
}
