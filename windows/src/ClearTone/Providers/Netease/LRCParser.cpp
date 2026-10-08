#include "Providers/Netease/LRCParser.h"

#include <QRegularExpression>

#include <algorithm>
#include <cmath>
#include <map>

namespace ct {

namespace {

const QRegularExpression& timePattern()
{
    static const QRegularExpression pattern(
        QStringLiteral(R"(\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\])"));
    return pattern;
}

const QRegularExpression& yrcLinePattern()
{
    static const QRegularExpression pattern(QStringLiteral(R"(\[(\d+),(\d+)\]([^\[]*))"));
    return pattern;
}

const QRegularExpression& yrcWordPattern()
{
    static const QRegularExpression pattern(QStringLiteral(R"(([^(]+)\((\d+),(\d+),\d+\))"));
    return pattern;
}

double parseDouble(const QString& text)
{
    bool ok = false;
    const double value = text.toDouble(&ok);
    return ok ? value : 0.0;
}

bool byTime(const LyricLine& left, const LyricLine& right)
{
    return left.time < right.time;
}

QList<LyricLine> parseLrcText(const QString& lrc)
{
    QList<LyricLine> lines;
    const QStringList rawLines = lrc.split(QLatin1Char('\n'));
    for (QString line : rawLines) {
        while (line.endsWith(QLatin1Char('\r'))) line.chop(1);

        QList<QRegularExpressionMatch> matches;
        qsizetype textEnd = 0;
        QRegularExpressionMatchIterator iterator = timePattern().globalMatch(line);
        while (iterator.hasNext()) {
            const QRegularExpressionMatch match = iterator.next();
            matches.append(match);
            textEnd = qMax(textEnd, match.capturedEnd(0));
        }
        if (matches.isEmpty()) continue;

        const QString text = line.mid(textEnd).trimmed();
        for (const QRegularExpressionMatch& match : matches) {
            const double minutes = parseDouble(match.captured(1));
            const double seconds = parseDouble(match.captured(2));
            double fraction = 0.0;
            const QString fractionText = match.captured(3);
            if (!fractionText.isEmpty()) {
                fraction = parseDouble(fractionText)
                    / std::pow(10.0, static_cast<double>(fractionText.length()));
            }
            LyricLine lyric;
            lyric.time = minutes * 60 + seconds + fraction;
            lyric.text = text;
            lines.append(lyric);
        }
    }
    std::stable_sort(lines.begin(), lines.end(), byTime);
    return lines;
}

QList<LyricWord> parseYRCWords(const QString& content)
{
    QList<LyricWord> words;
    QRegularExpressionMatchIterator iterator = yrcWordPattern().globalMatch(content);
    while (iterator.hasNext()) {
        const QRegularExpressionMatch match = iterator.next();
        LyricWord word;
        word.time = parseDouble(match.captured(2)) / 1000.0;
        word.duration = parseDouble(match.captured(3)) / 1000.0;
        word.text = match.captured(1);
        words.append(word);
    }
    return words;
}

} // namespace

QList<LyricLine> LRCParser::parse(const QString& lrc,
    const std::optional<QString>& translation, const std::optional<QString>& romanization)
{
    const QList<LyricLine> mainLines = parseLrcText(lrc);
    const QList<LyricLine> transLines = translation ? parseLrcText(*translation) : QList<LyricLine>{};
    const QList<LyricLine> romaLines = romanization ? parseLrcText(*romanization) : QList<LyricLine>{};

    std::map<double, LyricLine> merged;
    for (const LyricLine& line : mainLines) merged[line.time] = line;
    for (const LyricLine& line : transLines) {
        const auto iterator = merged.find(line.time);
        if (iterator != merged.end()) iterator->second.translation = line.text;
    }
    for (const LyricLine& line : romaLines) {
        const auto iterator = merged.find(line.time);
        if (iterator != merged.end()) iterator->second.romanization = line.text;
    }

    QList<LyricLine> result;
    result.reserve(static_cast<qsizetype>(merged.size()));
    for (auto& entry : merged) result.append(entry.second);
    return result;
}

QList<LyricLine> LRCParser::parseYRC(const QString& yrc,
    const std::optional<QString>& translation, const std::optional<QString>& romanization)
{
    QList<LyricLine> lines;
    QRegularExpressionMatchIterator iterator = yrcLinePattern().globalMatch(yrc);
    while (iterator.hasNext()) {
        const QRegularExpressionMatch match = iterator.next();
        const double startMs = parseDouble(match.captured(1));
        const QString content = match.captured(3);
        const QList<LyricWord> words = parseYRCWords(content);

        LyricLine line;
        line.time = startMs / 1000.0;
        QString text;
        for (const LyricWord& word : words) text += word.text;
        line.text = text;
        line.words = words;
        lines.append(line);
    }

    if (translation && !translation->isEmpty()) {
        std::map<double, QString> translationMap;
        for (const LyricLine& line : parseLrcText(*translation)) translationMap[line.time] = line.text;
        for (LyricLine& line : lines) {
            const auto found = translationMap.find(line.time);
            if (found != translationMap.end()) line.translation = found->second;
        }
    }

    if (romanization && !romanization->isEmpty()) {
        std::map<double, QString> romanizationMap;
        for (const LyricLine& line : parseLrcText(*romanization)) romanizationMap[line.time] = line.text;
        for (LyricLine& line : lines) {
            const auto found = romanizationMap.find(line.time);
            if (found != romanizationMap.end()) line.romanization = found->second;
        }
    }

    std::stable_sort(lines.begin(), lines.end(), byTime);
    return lines;
}

std::optional<int> LRCParser::currentLineIndex(
    const QList<LyricLine>& lines, double time, double offset)
{
    if (lines.isEmpty()) return std::nullopt;
    const double adjusted = time + offset;
    int low = 0;
    int high = static_cast<int>(lines.size()) - 1;
    std::optional<int> result;

    while (low <= high) {
        const int mid = (low + high) / 2;
        if (lines.at(mid).time <= adjusted) {
            result = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }
    return result;
}

} // namespace ct
