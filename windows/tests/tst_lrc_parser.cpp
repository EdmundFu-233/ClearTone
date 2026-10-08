#include <QtTest>

#include "Core/Models/MusicModels.h"
#include "Providers/Netease/LRCParser.h"

#include <cmath>

using namespace ct;

namespace {

QList<LyricLine> makeTimedLines()
{
    QList<LyricLine> lines;
    const QList<QPair<double, QString>> entries = {{1.0, QStringLiteral("a")},
        {5.0, QStringLiteral("b")}, {10.0, QStringLiteral("c")}, {20.0, QStringLiteral("d")}};
    for (const auto& [time, text] : entries) {
        LyricLine line;
        line.time = time;
        line.text = text;
        lines.append(line);
    }
    return lines;
}

} // namespace

class LRCParserTests : public QObject {
    Q_OBJECT

private slots:
    void testBasicLRC();
    void testDuplicateTimestamps();
    void testMalformedLines();
    void testTranslationMerge();
    void testBinarySearch();
    void testBinarySearchWithOffset();
    void testYRC();
    void testYRCMergesRomanization();
};

void LRCParserTests::testBasicLRC()
{
    const QList<LyricLine> lines = LRCParser::parse(
        QStringLiteral("[00:01.00]第一行\n[00:05.50]第二行\n[00:10.00]第三行"));
    QCOMPARE(lines.size(), 3);
    QVERIFY(std::abs(lines[0].time - 1.0) < 1e-3);
    QVERIFY(std::abs(lines[1].time - 5.5) < 1e-3);
    QCOMPARE(lines[0].text, QStringLiteral("第一行"));
}

void LRCParserTests::testDuplicateTimestamps()
{
    const QList<LyricLine> lines = LRCParser::parse(
        QStringLiteral("[00:01.00]同一时间\n[00:01.00]重复时间\n[00:02.00]下一行"));
    QCOMPARE(lines.size(), 2);
    QCOMPARE(lines[0].text, QStringLiteral("重复时间"));
    QCOMPARE(lines[1].text, QStringLiteral("下一行"));
}

void LRCParserTests::testMalformedLines()
{
    const QList<LyricLine> lines =
        LRCParser::parse(QStringLiteral("[invalid]无效行\n[00:01.00]正常行\n[]\n[00:02.00]"));
    QCOMPARE(lines.size(), 2);
}

void LRCParserTests::testTranslationMerge()
{
    const QList<LyricLine> lines = LRCParser::parse(
        QStringLiteral("[00:01.00]你好"), QStringLiteral("[00:01.00]Hello"));
    QCOMPARE(lines.size(), 1);
    QVERIFY(lines[0].translation.has_value());
    QCOMPARE(*lines[0].translation, QStringLiteral("Hello"));
}

void LRCParserTests::testBinarySearch()
{
    const QList<LyricLine> lines = makeTimedLines();

    QVERIFY(!LRCParser::currentLineIndex(lines, 0).has_value());
    const auto atOne = LRCParser::currentLineIndex(lines, 1.0);
    QVERIFY(atOne && *atOne == 0);
    const auto atThree = LRCParser::currentLineIndex(lines, 3.0);
    QVERIFY(atThree && *atThree == 0);
    const auto atFive = LRCParser::currentLineIndex(lines, 5.0);
    QVERIFY(atFive && *atFive == 1);
    const auto atFifteen = LRCParser::currentLineIndex(lines, 15.0);
    QVERIFY(atFifteen && *atFifteen == 2);
    const auto atTwentyFive = LRCParser::currentLineIndex(lines, 25.0);
    QVERIFY(atTwentyFive && *atTwentyFive == 3);
}

void LRCParserTests::testBinarySearchWithOffset()
{
    QList<LyricLine> lines;
    LyricLine a;
    a.time = 5.0;
    a.text = QStringLiteral("a");
    lines.append(a);
    LyricLine b;
    b.time = 10.0;
    b.text = QStringLiteral("b");
    lines.append(b);

    const auto first = LRCParser::currentLineIndex(lines, 7.0, -2.0);
    QVERIFY(first && *first == 0);
    const auto second = LRCParser::currentLineIndex(lines, 3.0, 2.0);
    QVERIFY(second && *second == 0);
}

void LRCParserTests::testYRC()
{
    const QList<LyricLine> lines = LRCParser::parseYRC(QStringLiteral("[0,1000]我(0,200,0)们(200,300,0)"));
    QCOMPARE(lines.size(), 1);
    QVERIFY(lines[0].words.has_value());
    QCOMPARE(lines[0].words->size(), 2);
    QCOMPARE(lines[0].text, QStringLiteral("我们"));
}

void LRCParserTests::testYRCMergesRomanization()
{
    const QList<LyricLine> lines = LRCParser::parseYRC(QStringLiteral("[0,1000]我(0,200,0)们(200,300,0)"),
        QStringLiteral("[00:00.00]We"), QStringLiteral("[00:00.00]wo men"));
    QCOMPARE(lines.size(), 1);
    QVERIFY(lines[0].translation.has_value());
    QCOMPARE(*lines[0].translation, QStringLiteral("We"));
    QVERIFY(lines[0].romanization.has_value());
    QCOMPARE(*lines[0].romanization, QStringLiteral("wo men"));
}

QTEST_MAIN(LRCParserTests)
#include "tst_lrc_parser.moc"
