#include <QtTest>

#include "Playback/PlayingSourceInfo.h"

using namespace ct;

namespace {

AudioQuality makeQuality(
    QualityLevel level, std::optional<int> bitrate = std::nullopt, std::optional<QString> codec = std::nullopt)
{
    AudioQuality quality;
    quality.level = level;
    quality.bitrate = std::move(bitrate);
    quality.codec = std::move(codec);
    quality.isActual = true;
    return quality;
}

std::optional<PlayingSourceInfo> describe(const std::optional<AudioQuality>& quality,
    QualityLevel requested = QualityLevel::ExHigh, bool fromCache = false,
    const std::optional<QString>& cacheFormat = std::nullopt,
    const std::optional<int>& cacheBitrate = std::nullopt, bool caching = false)
{
    return playingSourceFormatter::describe(
        quality, requested, fromCache, cacheFormat, cacheBitrate, caching);
}

} // namespace

class PlayingSourceFormatterTests : public QObject {
    Q_OBJECT

private slots:
    void testFreshSongShowsStreamBitrateNotCache();
    void testCachingDoesNotReplaceStreamBitrate();
    void testCachedButStreamingOnlineKeepsStreamBitrate();
    void testPlayingFromCacheShowsCacheFormat();
    void testFromCacheWithoutMetaFallsBackToOnlineInfo();
    void testLevelWithoutBitrateShowsLevelOnly();
    void testCodecWithoutBitrateShowsCodec();
    void testCodecIsNormalized();
    void testUnknownQualityWithoutBitrateIsHidden();
    void testNonPositiveBitrateIsIgnored();
    void testDetailContainsRequestedAndActualQuality();
};

void PlayingSourceFormatterTests::testFreshSongShowsStreamBitrateNotCache()
{
    const auto info = describe(makeQuality(QualityLevel::ExHigh, 320, QStringLiteral("mp3")));
    QVERIFY(info.has_value());
    QCOMPARE(info->text, QStringLiteral("MP3 320k"));
    QCOMPARE(info->shortText, QStringLiteral("320k"));
    QVERIFY(!info->isFromCache);
    QCOMPARE(info->cache.kind, CacheHint::Kind::None);
}

void PlayingSourceFormatterTests::testCachingDoesNotReplaceStreamBitrate()
{
    const auto info = describe(
        makeQuality(QualityLevel::ExHigh, 320, QStringLiteral("MP3")), QualityLevel::ExHigh,
        false, std::nullopt, std::nullopt, true);
    QVERIFY(info.has_value());
    QCOMPARE(info->text, QStringLiteral("MP3 320k"));
    QCOMPARE(info->cache.kind, CacheHint::Kind::Caching);
    QVERIFY(info->detail.contains(QStringLiteral("正在写入")));
}

void PlayingSourceFormatterTests::testCachedButStreamingOnlineKeepsStreamBitrate()
{
    const auto info = describe(makeQuality(QualityLevel::Lossless, 1411, QStringLiteral("flac")),
        QualityLevel::ExHigh, false, QStringLiteral("OPUS"), 128);
    QVERIFY(info.has_value());
    QCOMPARE(info->text, QStringLiteral("FLAC 1411k"));
    QVERIFY(!info->isFromCache);
    QCOMPARE(info->cache.kind, CacheHint::Kind::Cached);
    QCOMPARE(info->cache.format, QStringLiteral("OPUS"));
    QCOMPARE(info->cache.bitrateKbps, 128);
    QVERIFY(info->detail.contains(QStringLiteral("下次播放优先使用")));
}

void PlayingSourceFormatterTests::testPlayingFromCacheShowsCacheFormat()
{
    const auto info = describe(makeQuality(QualityLevel::Unknown, 128), QualityLevel::ExHigh,
        true, QStringLiteral("OPUS"), 128);
    QVERIFY(info.has_value());
    QCOMPARE(info->text, QStringLiteral("OPUS 128k"));
    QCOMPARE(info->shortText, QStringLiteral("OPUS 128k"));
    QVERIFY(info->isFromCache);
    QVERIFY(info->detail.contains(QStringLiteral("正在播放本地缓存")));
}

void PlayingSourceFormatterTests::testFromCacheWithoutMetaFallsBackToOnlineInfo()
{
    const auto info =
        describe(makeQuality(QualityLevel::ExHigh, 320), QualityLevel::ExHigh, true);
    QVERIFY(info.has_value());
    QCOMPARE(info->text, QStringLiteral("极高 320k"));
    QVERIFY(!info->isFromCache);
}

void PlayingSourceFormatterTests::testLevelWithoutBitrateShowsLevelOnly()
{
    const auto info = describe(makeQuality(QualityLevel::Standard));
    QVERIFY(info.has_value());
    QCOMPARE(info->text, QStringLiteral("标准"));
    QCOMPARE(info->shortText, QStringLiteral("标准"));
}

void PlayingSourceFormatterTests::testCodecWithoutBitrateShowsCodec()
{
    const auto info = describe(makeQuality(QualityLevel::Unknown, std::nullopt, QStringLiteral("flac")));
    QVERIFY(info.has_value());
    QCOMPARE(info->text, QStringLiteral("FLAC"));
}

void PlayingSourceFormatterTests::testCodecIsNormalized()
{
    const auto info = describe(makeQuality(QualityLevel::ExHigh, 320, QStringLiteral(" mp3 ")));
    QVERIFY(info.has_value());
    QCOMPARE(info->text, QStringLiteral("MP3 320k"));

    const auto blank = describe(makeQuality(QualityLevel::ExHigh, 320, QStringLiteral("  ")));
    QVERIFY(blank.has_value());
    QCOMPARE(blank->text, QStringLiteral("极高 320k"));
}

void PlayingSourceFormatterTests::testUnknownQualityWithoutBitrateIsHidden()
{
    QVERIFY(!describe(makeQuality(QualityLevel::Unknown)).has_value());
    QVERIFY(!describe(std::nullopt).has_value());
}

void PlayingSourceFormatterTests::testNonPositiveBitrateIsIgnored()
{
    QVERIFY(!describe(makeQuality(QualityLevel::Unknown, 0)).has_value());
}

void PlayingSourceFormatterTests::testDetailContainsRequestedAndActualQuality()
{
    const auto info = describe(makeQuality(QualityLevel::Higher, 192, QStringLiteral("AAC")),
        QualityLevel::ExHigh);
    QVERIFY(info.has_value());
    QVERIFY(info->detail.contains(QStringLiteral("编码：AAC")));
    QVERIFY(info->detail.contains(QStringLiteral("请求音质：极高")));
    QVERIFY(info->detail.contains(QStringLiteral("实际返回：较高 192kbps")));
    QVERIFY(info->detail.contains(QStringLiteral("本地缓存：无")));
}

QTEST_MAIN(PlayingSourceFormatterTests)
#include "tst_playing_source.moc"
