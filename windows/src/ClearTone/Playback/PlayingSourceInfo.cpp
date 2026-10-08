#include "Playback/PlayingSourceInfo.h"

namespace ct {

namespace playingSourceFormatter {

namespace {

QString primaryText(QualityLevel level, const std::optional<int>& bitrate, const std::optional<QString>& codec)
{
    const QString cleanCodec = codec ? codec->trimmed().toUpper() : QString();
    const bool hasCodec = !cleanCodec.isEmpty();
    const std::optional<QString> rate =
        bitrate && *bitrate > 0 ? std::optional<QString>(QStringLiteral("%1k").arg(*bitrate)) : std::nullopt;
    if (hasCodec && rate) return QStringLiteral("%1 %2").arg(cleanCodec, *rate);
    if (hasCodec) return cleanCodec;
    if (rate) {
        return level == QualityLevel::Unknown ? *rate : QStringLiteral("%1 %2").arg(quality::displayName(level), *rate);
    }
    if (level == QualityLevel::Unknown) return QString();
    return quality::displayName(level);
}

} // namespace

std::optional<PlayingSourceInfo> describe(const std::optional<AudioQuality>& actualQuality,
    QualityLevel requestedLevel, bool isFromCache, const std::optional<QString>& cacheFormat,
    const std::optional<int>& cacheBitrateKbps, bool isCaching)
{
    CacheHint cache;
    if (cacheFormat && cacheBitrateKbps && *cacheBitrateKbps > 0) {
        cache = CacheHint::cached(*cacheFormat, *cacheBitrateKbps);
    } else if (isCaching) {
        cache = CacheHint::caching();
    } else {
        cache = CacheHint::none();
    }

    if (isFromCache && cache.kind == CacheHint::Kind::Cached) {
        const QString cachedText = QStringLiteral("%1 %2k").arg(cache.format).arg(cache.bitrateKbps);
        PlayingSourceInfo info;
        info.text = cachedText;
        info.shortText = cachedText;
        info.isFromCache = true;
        info.cache = cache;
        info.detail = QStringLiteral("正在播放本地缓存：%1 %2kbps\n本地缓存优先于在线流")
                          .arg(cache.format)
                          .arg(cache.bitrateKbps);
        return info;
    }

    if (!actualQuality) return std::nullopt;
    const QualityLevel level = actualQuality->level;
    const std::optional<int>& bitrate = actualQuality->bitrate;
    const QString text = primaryText(level, bitrate, actualQuality->codec);
    if (text.isEmpty()) return std::nullopt;

    const QString actualLine = bitrate ? QStringLiteral("%1 %2kbps").arg(quality::displayName(level)).arg(*bitrate)
                                       : quality::displayName(level);
    const QString codecLine =
        actualQuality->codec ? QStringLiteral("\n编码：%1").arg(*actualQuality->codec) : QString();
    QString cacheLine;
    switch (cache.kind) {
    case CacheHint::Kind::Caching:
        cacheLine = QStringLiteral("本地缓存：正在写入（本次播放仍为在线流）");
        break;
    case CacheHint::Kind::Cached:
        cacheLine = QStringLiteral("本地缓存：%1 %2kbps（下次播放优先使用）")
                        .arg(cache.format)
                        .arg(cache.bitrateKbps);
        break;
    case CacheHint::Kind::None:
        cacheLine = QStringLiteral("本地缓存：无");
        break;
    }

    PlayingSourceInfo info;
    info.text = text;
    info.shortText = bitrate ? QStringLiteral("%1k").arg(*bitrate) : text;
    info.isFromCache = false;
    info.cache = cache;
    info.detail = QStringLiteral("请求音质：%1\n实际返回：%2%3%4")
                      .arg(quality::displayName(requestedLevel), actualLine, codecLine, cacheLine);
    return info;
}

} // namespace playingSourceFormatter

} // namespace ct
