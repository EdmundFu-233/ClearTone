import XCTest
import Foundation

/// 音源描述的文案规则。
///
/// 核心约束（来自实际使用反馈）：**第一次听的歌必须显示在线流的码率**。
/// 后台缓存是「一开始播就写」，所以如果让缓存状态顶掉码率，
/// 一首新歌从点播放到听完，界面上显示的一直是「缓存中 / OPUS 96k」，
/// 而它此刻播的是 320k 在线流 —— 显示的码率和耳朵听到的对不上。
final class PlayingSourceFormatterTests: XCTestCase {

    private func describe(
        quality: AudioQuality?,
        requested: AudioQuality.QualityLevel = .exhigh,
        fromCache: Bool = false,
        cacheFormat: String? = nil,
        cacheBitrate: Int? = nil,
        caching: Bool = false
    ) -> PlayingSourceInfo? {
        PlayingSourceFormatter.describe(
            actualQuality: quality,
            requestedLevel: requested,
            isFromCache: fromCache,
            cacheFormat: cacheFormat,
            cacheBitrateKbps: cacheBitrate,
            isCaching: caching
        )
    }

    // MARK: 第一次听（无缓存 / 正在缓存）

    func testFreshSongShowsStreamBitrateNotCache() throws {
        let info = try XCTUnwrap(describe(quality: AudioQuality(level: .exhigh, bitrate: 320, isActual: true, codec: "mp3")))
        XCTAssertEqual(info.text, "MP3 320k", "主文案必须是「编码 + 码率」，不是网易云的档位名")
        XCTAssertEqual(info.shortText, "320k")
        XCTAssertFalse(info.isFromCache)
        XCTAssertEqual(info.cache, .none)
    }

    /// 正在写缓存时也不能改主文案 —— 此刻耳朵听到的还是在线流
    func testCachingDoesNotReplaceStreamBitrate() throws {
        let info = try XCTUnwrap(describe(
            quality: AudioQuality(level: .exhigh, bitrate: 320, isActual: true, codec: "MP3"),
            caching: true
        ))
        XCTAssertEqual(info.text, "MP3 320k", "缓存状态不该顶掉此刻实际在放的编码与码率")
        XCTAssertEqual(info.cache, .caching)
        XCTAssertTrue(info.detail.contains("正在写入"), "tooltip 要说明缓存正在写入")
    }

    /// 已经有缓存、但这次播的是在线流：主信息仍是码率，缓存只作旁注
    func testCachedButStreamingOnlineKeepsStreamBitrate() throws {
        let info = try XCTUnwrap(describe(
            quality: AudioQuality(level: .lossless, bitrate: 1411, isActual: true, codec: "flac"),
            cacheFormat: "OPUS", cacheBitrate: 96
        ))
        XCTAssertEqual(info.text, "FLAC 1411k")
        XCTAssertFalse(info.isFromCache)
        XCTAssertEqual(info.cache, .cached(format: "OPUS", bitrateKbps: 96))
        XCTAssertTrue(info.detail.contains("下次播放优先使用"))
    }

    // MARK: 真的在播缓存文件

    func testPlayingFromCacheShowsCacheFormat() throws {
        let info = try XCTUnwrap(describe(
            quality: AudioQuality(level: .unknown, bitrate: 96, isActual: true),
            fromCache: true,
            cacheFormat: "OPUS", cacheBitrate: 96
        ))
        XCTAssertEqual(info.text, "OPUS 96k", "在播缓存文件时，缓存格式就是实际音质")
        XCTAssertEqual(info.shortText, "OPUS 96k", "在播缓存时紧凑形态也要带编码")
        XCTAssertTrue(info.isFromCache)
        XCTAssertTrue(info.detail.contains("正在播放本地缓存"))
    }

    /// 缓存元信息缺失时不该退回「未知」这种没意义的文案
    func testFromCacheWithoutMetaFallsBackToOnlineInfo() {
        let info = describe(
            quality: AudioQuality(level: .exhigh, bitrate: 320, isActual: true),
            fromCache: true
        )
        XCTAssertEqual(info?.text, "极高 320k")
        XCTAssertEqual(info?.isFromCache, false)
    }

    // MARK: 拿不到码率

    func testLevelWithoutBitrateShowsLevelOnly() throws {
        let info = try XCTUnwrap(describe(quality: AudioQuality(level: .standard, isActual: true)))
        XCTAssertEqual(info.text, "标准")
        XCTAssertEqual(info.shortText, "标准")
    }

    /// 有编码没码率：只显示编码（总比只写个档位名有用）
    func testCodecWithoutBitrateShowsCodec() throws {
        let info = try XCTUnwrap(describe(quality: AudioQuality(level: .unknown, isActual: true, codec: "flac")))
        XCTAssertEqual(info.text, "FLAC")
    }

    /// 编码大小写/空白要归一，不能把 " mp3 " 直接印到界面上
    func testCodecIsNormalized() throws {
        let info = try XCTUnwrap(describe(quality: AudioQuality(level: .exhigh, bitrate: 320, isActual: true, codec: " mp3 ")))
        XCTAssertEqual(info.text, "MP3 320k")
        let blank = try XCTUnwrap(describe(quality: AudioQuality(level: .exhigh, bitrate: 320, isActual: true, codec: "  ")))
        XCTAssertEqual(blank.text, "极高 320k", "空编码应当退回档位名")
    }

    /// 本地文件：level 是 .unknown 又没有码率，没有任何可展示信息 → nil
    func testUnknownQualityWithoutBitrateIsHidden() {
        XCTAssertNil(describe(quality: AudioQuality(level: .unknown, isActual: true)))
        XCTAssertNil(describe(quality: nil))
    }

    func testNonPositiveBitrateIsIgnored() {
        XCTAssertNil(describe(quality: AudioQuality(level: .unknown, bitrate: 0, isActual: true)))
    }

    // MARK: tooltip 内容

    func testDetailContainsRequestedAndActualQuality() throws {
        let info = try XCTUnwrap(describe(
            quality: AudioQuality(level: .higher, bitrate: 192, isActual: true, codec: "AAC"),
            requested: .exhigh
        ))
        XCTAssertTrue(info.detail.contains("编码：AAC"))
        XCTAssertTrue(info.detail.contains("请求音质：极高"))
        XCTAssertTrue(info.detail.contains("实际返回：较高 192kbps"), "tooltip 要带实际码率")
        XCTAssertTrue(info.detail.contains("本地缓存：无"))
    }
}
