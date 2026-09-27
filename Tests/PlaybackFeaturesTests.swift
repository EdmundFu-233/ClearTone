import XCTest

/// P1 新增能力的可测部分：倍速、睡眠定时器文案、歌词偏移、YRC 逐字、频谱选项。
@MainActor
final class PlaybackFeaturesTests: XCTestCase {

    private var originalRate: Float = 1.0

    override func setUp() async throws {
        originalRate = PlayerController.shared.playbackRate
    }

    override func tearDown() async throws {
        PlayerController.shared.setPlaybackRate(originalRate)
        PlayerController.shared.cancelSleepTimer()
    }

    // MARK: - 倍速

    func testRateClampsToSaneRange() {
        let player = PlayerController.shared
        player.setPlaybackRate(1.5)
        XCTAssertEqual(player.playbackRate, 1.5, accuracy: 0.001)

        // 上限：不能快到把流媒体彻底打崩
        player.setPlaybackRate(99)
        XCTAssertEqual(player.playbackRate, 3.0, accuracy: 0.001)
        // 下限：反向的荒谬值同理
        player.setPlaybackRate(0)
        XCTAssertEqual(player.playbackRate, 0.25, accuracy: 0.001)
        player.setPlaybackRate(-5)
        XCTAssertEqual(player.playbackRate, 0.25, accuracy: 0.001)
    }

    func testNormalRateHasNoBadge() {
        let player = PlayerController.shared
        player.setPlaybackRate(1.0)
        XCTAssertFalse(player.isRateAdjusted, "1.0x 不该显示倍率徽标")
        XCTAssertEqual(player.playbackRateLabel, "")

        player.setPlaybackRate(1.5)
        XCTAssertTrue(player.isRateAdjusted)
        XCTAssertFalse(player.playbackRateLabel.isEmpty, "非 1.0x 必须有可见反馈")
        XCTAssertTrue(player.playbackRateLabel.contains("1.5"))
    }

    /// 2.0x 要显示成「2×」而不是「2×」以外的奇怪形式
    func testRateLabelFormatting() {
        XCTAssertEqual(PlayerController.rateLabel(2.0), "2×")
        XCTAssertEqual(PlayerController.rateLabel(0.5), "0.5×")
    }

    /// 回归：`%.2g` 是**两位有效数字**，1.25 会显示成「1.2×」、1.75 显示成「1.8×」。
    /// 播的是 1.25x 界面却说 1.2x，用户无从判断到底设成了多少。
    func testQuarterRatesAreNotRoundedAway() {
        let expected: [Float: String] = [
            0.5: "0.5×", 0.75: "0.75×", 1.0: "1×", 1.25: "1.25×",
            1.5: "1.5×", 1.75: "1.75×", 2.0: "2×",
        ]
        XCTAssertEqual(Set(PlayerController.availableRates), Set(expected.keys))
        for rate in PlayerController.availableRates {
            XCTAssertEqual(
                PlayerController.rateLabel(rate), expected[rate],
                "\(rate)x 的标签把有效数字吃掉了"
            )
        }
    }

    /// 档位必须单调递增且以 1.0 为中心
    func testAvailableRatesAreOrderedAndCentred() {
        let rates = PlayerController.availableRates
        XCTAssertEqual(rates, rates.sorted(), "档位必须递增")
        XCTAssertTrue(rates.contains(1.0), "必须有正常速度这一档")
        XCTAssertGreaterThanOrEqual(rates.first ?? 0, 0.25)
        XCTAssertLessThanOrEqual(rates.last ?? 99, 3.0)
    }

    // MARK: - 睡眠定时器

    func testSleepTimerSetsAndCancels() {
        let player = PlayerController.shared
        XCTAssertNil(player.sleepTimerEndDate)

        player.setSleepTimer(minutes: 15)
        XCTAssertNotNil(player.sleepTimerEndDate)
        XCTAssertEqual(player.sleepTimerRemaining, 15 * 60, accuracy: 1.0)
        XCTAssertTrue(player.sleepTimerEndDate! > Date(), "到期时间必须在未来")

        player.cancelSleepTimer()
        XCTAssertNil(player.sleepTimerEndDate)
        XCTAssertEqual(player.sleepTimerRemaining, 0, accuracy: 0.001)
    }

    /// 传 0 或负数等同取消，而不是创建一个立刻到期的定时器
    func testNonPositiveSleepTimerCancels() {
        let player = PlayerController.shared
        player.setSleepTimer(minutes: 30)
        player.setSleepTimer(minutes: 0)
        XCTAssertNil(player.sleepTimerEndDate)

        player.setSleepTimer(minutes: 30)
        player.setSleepTimer(minutes: -5)
        XCTAssertNil(player.sleepTimerEndDate)
    }

    /// 重新设置会替换掉旧的倒计时，不该有两个任务同时在跑
    func testSleepTimerReplacesPrevious() {
        let player = PlayerController.shared
        player.setSleepTimer(minutes: 60)
        let first = player.sleepTimerEndDate
        player.setSleepTimer(minutes: 10)
        let second = player.sleepTimerEndDate
        XCTAssertNotNil(second)
        XCTAssertTrue(second! < first!, "新的到期时间应当更早")
    }

    // MARK: - 睡眠定时器倒计时文案

    func testSleepRemainingLabel() {
        XCTAssertEqual(PlaybackUtilitiesMenu.remainingLabel(0), "0秒")
        XCTAssertEqual(PlaybackUtilitiesMenu.remainingLabel(45), "45秒")
        XCTAssertEqual(PlaybackUtilitiesMenu.remainingLabel(90), "1分30秒")
        XCTAssertEqual(PlaybackUtilitiesMenu.remainingLabel(3600), "1时0分")
        XCTAssertEqual(PlaybackUtilitiesMenu.remainingLabel(3900), "1时5分")
        // 负数（定时器刚到点、UI 还没来得及刷新）不能显示成 "-3秒"
        XCTAssertEqual(PlaybackUtilitiesMenu.remainingLabel(-3), "0秒")
    }

    // MARK: - 频谱选项

    /// 「真实频谱」拿不到采样，留着就是欺骗用户（spec §13 明令禁止假频谱）
    func testSpectrumModeDoesNotOfferRealSpectrum() {
        XCTAssertFalse(
            AppSettings.SpectrumMode.allCases.contains { $0.rawValue == "真实频谱" },
            "真实频谱拿不到音频采样，不该作为选项呈现"
        )
        XCTAssertEqual(AppSettings.SpectrumMode.allCases.count, 2)
        XCTAssertTrue(AppSettings.SpectrumMode.allCases.contains(.ambient))
        XCTAssertTrue(AppSettings.SpectrumMode.allCases.contains(.off))
    }

    /// 默认必须是环境动画 —— 原先默认 `.real`，而那条路什么都不画
    func testSpectrumDefaultIsAmbient() {
        let settings = AppSettings()
        XCTAssertEqual(settings.spectrumMode, .ambient)
    }

    /// 老用户存下的 `"真实频谱"` 不能让**整个** AppSettings 解码失败
    /// （否则主题、音质、缓存开关会被一起重置）
    ///
    /// 注意 rawValue 是中文（`"深色"` / `"无损"`），不是枚举 case 名。
    func testLegacySpectrumValueDoesNotBreakSettingsDecoding() throws {
        let legacy = """
        {"themeMode":"深色","spectrumMode":"真实频谱","lyricOffset":1.5,
         "preferredQuality":"无损","audioCacheEnabled":false}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.spectrumMode, .ambient, "未知枚举值应回落到 ambient")
        // 关键：其它字段必须完好
        XCTAssertEqual(decoded.themeMode, .dark, "themeMode 不该被旧枚举值拖累")
        XCTAssertEqual(decoded.preferredQuality, .lossless)
        XCTAssertFalse(decoded.audioCacheEnabled)
        XCTAssertEqual(decoded.lyricOffset, 1.5, accuracy: 0.0001)
    }

    /// 回归：合成 `init(from:)` 是整体成败的，任何一个键不认识就全盘重置。
    /// 这里逐个字段破坏，验证只有那一个字段回落。
    func testUnrecognizedFieldDoesNotResetTheRest() throws {
        let broken = """
        {"themeMode":"chartreuse","closeBehavior":"fly-to-the-moon",
         "performanceMode":"turbo","spectrumMode":42,"lyricOffset":"soon",
         "preferredQuality":"无损","audioCacheEnabled":false,"miniPlayerAlwaysOnTop":false}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(broken.utf8))
        // 坏的字段各自回落到默认
        XCTAssertEqual(decoded.themeMode, .system)
        XCTAssertEqual(decoded.closeBehavior, .keepPlaying)
        XCTAssertEqual(decoded.performanceMode, .auto)
        XCTAssertEqual(decoded.spectrumMode, .ambient)
        XCTAssertEqual(decoded.lyricOffset, 0)
        // 好字段一个都不能丢
        XCTAssertEqual(decoded.preferredQuality, .lossless)
        XCTAssertFalse(decoded.audioCacheEnabled)
        XCTAssertFalse(decoded.miniPlayerAlwaysOnTop)
    }

    /// 完全没有 appSettings 键（老版本升级）时也要拿到一份完整默认值
    func testEmptyObjectDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.closeBehavior, .keepPlaying)
        XCTAssertFalse(decoded.menuBarAlwaysVisible)
        XCTAssertTrue(decoded.miniPlayerAlwaysOnTop)
        XCTAssertTrue(decoded.audioCacheEnabled)
        XCTAssertEqual(decoded.preferredQuality, .exhigh)
    }

    /// 存下去再读出来必须一致 —— `menuBarAlwaysVisible` 是新增字段，
    /// 编码侧漏了它的话这个开关重启就复位
    func testSettingsRoundTripKeepsMenuBarFlag() throws {
        var settings = AppSettings()
        settings.menuBarAlwaysVisible = true
        settings.closeBehavior = .minimizeToMenuBar
        settings.miniPlayerAlwaysOnTop = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.menuBarAlwaysVisible)
        XCTAssertEqual(decoded.closeBehavior, .minimizeToMenuBar)
        XCTAssertFalse(decoded.miniPlayerAlwaysOnTop)
    }

    // MARK: - 菜单栏显隐

    func testCloseBehaviorDefaultKeepsPlaying() {
        // 默认必须与历史的 applicationShouldTerminateAfterLastWindowClosed == false 一致，
        // 否则升级即改变用户预期
        XCTAssertEqual(AppSettings().closeBehavior, .keepPlaying)
        XCTAssertFalse(AppSettings().menuBarAlwaysVisible, "默认不常驻菜单栏图标")
    }

    /// 每个关闭行为都要有可读说明（设置页 tooltip 直接用它）
    func testEveryCloseBehaviorHasHelp() {
        for behavior in AppSettings.CloseBehavior.allCases {
            XCTAssertFalse(behavior.help.isEmpty, "\(behavior) 缺少说明")
            XCTAssertFalse(behavior.displayName.isEmpty)
        }
        XCTAssertEqual(AppSettings.CloseBehavior.allCases.count, 3)
    }

    /// 「菜单栏常驻」优先于任何关窗行为
    func testMenuBarAlwaysVisibleWinsOverEveryCloseBehavior() {
        for behavior in AppSettings.CloseBehavior.allCases {
            for hasWindow in [true, false] {
                XCTAssertTrue(
                    MenuBarVisibilityPolicy.showsStatusItem(
                        menuBarAlwaysVisible: true,
                        closeBehavior: behavior,
                        hasVisibleWindow: hasWindow
                    ),
                    "常驻开启时不该看得到窗口与关窗行为"
                )
            }
        }
    }

    /// 「缩到菜单栏」：有窗口时不出现（窗口本身就是入口），关掉后必须出现
    func testMinimizeToMenuBarShowsIconOnlyWithoutWindow() {
        XCTAssertFalse(MenuBarVisibilityPolicy.showsStatusItem(
            menuBarAlwaysVisible: false, closeBehavior: .minimizeToMenuBar, hasVisibleWindow: true
        ))
        XCTAssertTrue(MenuBarVisibilityPolicy.showsStatusItem(
            menuBarAlwaysVisible: false, closeBehavior: .minimizeToMenuBar, hasVisibleWindow: false
        ))
    }

    /// 回归：这三种情况以前都会挂着一个删不掉的图标 ——
    /// `MenuBarExtra` 是常驻声明，写进 `body` 就没法在运行时隐藏。
    /// 「继续后台播放」有 ⌘⇧M 的迷你播放器兜底，「退出应用」没有「关窗之后」。
    func testNoIconForKeepPlayingOrQuit() {
        for behavior in [AppSettings.CloseBehavior.keepPlaying, .quit] {
            for hasWindow in [true, false] {
                XCTAssertFalse(
                    MenuBarVisibilityPolicy.showsStatusItem(
                        menuBarAlwaysVisible: false,
                        closeBehavior: behavior,
                        hasVisibleWindow: hasWindow
                    ),
                    "\(behavior) 不该显示菜单栏图标"
                )
            }
        }
    }
}
