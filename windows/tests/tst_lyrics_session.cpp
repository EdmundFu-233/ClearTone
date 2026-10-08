#include <QtTest>

#include "Core/Lyrics/LyricsSession.h"
#include "TestSupport.h"

using namespace ct;
using namespace ct::tests;

namespace {

Song makeSong(const QString& id)
{
    Song song;
    song.id = id;
    song.title = QStringLiteral("歌-%1").arg(id);
    Artist artist;
    artist.id = QStringLiteral("a1");
    artist.name = QStringLiteral("人");
    song.artists.append(artist);
    song.source = SongSource::Netease;
    return song;
}

LyricLine line(double time, const QString& text)
{
    LyricLine result;
    result.time = time;
    result.text = text;
    return result;
}

LyricResult lyricsFrom(const QString& text)
{
    LyricResult result;
    result.lines = {line(0, text)};
    return result;
}

QStringList lineTexts(const QList<LyricLine>& lines)
{
    QStringList texts;
    for (const LyricLine& item : lines) texts.append(item.text);
    return texts;
}

} // namespace

class LyricsSessionTests : public QObject {
    Q_OBJECT

private slots:
    void testLoadPopulatesLinesAndFlags();
    void testPureMusicFlagIsSurfaced();
    void testNilSongClearsWithoutRequest();
    void testUnresolvableSongIsSkipped();
    void testFailureSurfacesErrorAndKeepsLinesEmpty();
    void testSwitchingSongClearsLinesBeforeResponse();
    void testLateResponseFromPreviousSongIsDiscarded();
    void testCancelledLoadResetsLoading();
    void testResetClearsEverythingSynchronously();
    void testAlreadyCancelledLoadDoesNotClearState();
};

void LyricsSessionTests::testLoadPopulatesLinesAndFlags()
{
    StubMusicProvider provider;
    provider.lyricsHandler = [](const QString&, CancellationToken) {
        LyricResult result;
        result.lines = {line(0, QStringLiteral("第一行")), line(3, QStringLiteral("第二行"))};
        result.hasWordTiming = true;
        result.isPureMusic = false;
        return makeReadyTask(result);
    };
    LyricsSession session([&provider](const Song&) { return &provider; });

    Song song = makeSong(QStringLiteral("1"));
    syncWait(session.loadAsync(&song));

    QCOMPARE(lineTexts(session.lines()),
        QStringList({QStringLiteral("第一行"), QStringLiteral("第二行")}));
    QVERIFY(session.hasWordTiming());
    QVERIFY(!session.isPureMusic());
    QVERIFY(!session.errorMessage().has_value());
    QVERIFY(!session.isLoading());
}

void LyricsSessionTests::testPureMusicFlagIsSurfaced()
{
    StubMusicProvider provider;
    provider.lyricsHandler = [](const QString&, CancellationToken) {
        LyricResult result;
        result.hasWordTiming = false;
        result.isPureMusic = true;
        return makeReadyTask(result);
    };
    LyricsSession session([&provider](const Song&) { return &provider; });

    Song song = makeSong(QStringLiteral("1"));
    syncWait(session.loadAsync(&song));

    QVERIFY(session.isPureMusic());
    QVERIFY(session.lines().isEmpty());
}

void LyricsSessionTests::testNilSongClearsWithoutRequest()
{
    StubMusicProvider provider;
    provider.lyricsHandler = [](const QString&, CancellationToken) {
        return makeReadyTask(lyricsFrom(QStringLiteral("旧词")));
    };
    LyricsSession session([&provider](const Song&) { return &provider; });
    Song song = makeSong(QStringLiteral("1"));
    syncWait(session.loadAsync(&song));
    QVERIFY(!session.lines().isEmpty());

    syncWait(session.loadAsync(nullptr));

    QVERIFY(session.lines().isEmpty());
    QVERIFY(!session.isLoading());
    QCOMPARE(provider.lyricRequests.size(), 1);
}

void LyricsSessionTests::testUnresolvableSongIsSkipped()
{
    StubMusicProvider provider;
    LyricsSession session([](const Song&) -> IMusicProvider* { return nullptr; });

    Song song = makeSong(QStringLiteral("1"));
    syncWait(session.loadAsync(&song));

    QVERIFY(session.lines().isEmpty());
    QVERIFY(!session.isLoading());
    QVERIFY(provider.lyricRequests.isEmpty());
}

void LyricsSessionTests::testFailureSurfacesErrorAndKeepsLinesEmpty()
{
    StubMusicProvider provider;
    provider.lyricsHandler = [](const QString&, CancellationToken) -> Task<LyricResult> {
        throw MusicException::networkUnavailable();
    };
    LyricsSession session([&provider](const Song&) { return &provider; });

    Song song = makeSong(QStringLiteral("1"));
    syncWait(session.loadAsync(&song));

    QVERIFY(session.errorMessage().has_value());
    QVERIFY(session.lines().isEmpty());
    QVERIFY(!session.isLoading());
}

void LyricsSessionTests::testSwitchingSongClearsLinesBeforeResponse()
{
    StubMusicProvider provider;
    provider.lyricsHandler = [](const QString&, CancellationToken) {
        return makeReadyTask(lyricsFrom(QStringLiteral("A 的词")));
    };
    LyricsSession session([&provider](const Song&) { return &provider; });
    Song songA = makeSong(QStringLiteral("A"));
    syncWait(session.loadAsync(&songA));
    QCOMPARE(lineTexts(session.lines()), QStringList{QStringLiteral("A 的词")});

    auto gate = std::make_shared<TestGate>();
    provider.lyricsHandler = [gate](const QString&, CancellationToken) -> Task<LyricResult> {
        co_await *gate;
        co_return lyricsFrom(QStringLiteral("B 的词"));
    };
    Song songB = makeSong(QStringLiteral("B"));
    auto task = session.loadAsync(&songB);
    task.start();

    QVERIFY(session.lines().isEmpty());
    QVERIFY(session.isLoading());

    gate->open();
    QVERIFY2(until([&] { return task.isDone(); }), "B 的请求未结束");
    QCOMPARE(lineTexts(session.lines()), QStringList{QStringLiteral("B 的词")});
}

void LyricsSessionTests::testLateResponseFromPreviousSongIsDiscarded()
{
    auto gateA = std::make_shared<TestGate>();
    auto gateB = std::make_shared<TestGate>();
    StubMusicProvider provider;
    provider.lyricsHandler = [gateA, gateB](const QString& songID, CancellationToken) -> Task<LyricResult> {
        if (songID == QStringLiteral("A")) {
            co_await *gateA;
            co_return lyricsFrom(QStringLiteral("A 的词"));
        }
        co_await *gateB;
        co_return lyricsFrom(QStringLiteral("B 的词"));
    };
    LyricsSession session([&provider](const Song&) { return &provider; });

    Song songA = makeSong(QStringLiteral("A"));
    auto first = session.loadAsync(&songA);
    first.start();
    QVERIFY2(until([&] { return provider.lyricRequests.size() == 1; }), "A 的请求未发出");

    Song songB = makeSong(QStringLiteral("B"));
    auto second = session.loadAsync(&songB);
    second.start();
    QVERIFY2(until([&] { return provider.lyricRequests.size() == 2; }), "B 的请求未发出");

    gateA->open();
    QVERIFY2(until([&] { return first.isDone(); }), "A 的请求未结束");
    QVERIFY(session.lines().isEmpty());

    gateB->open();
    QVERIFY2(until([&] { return second.isDone(); }), "B 的请求未结束");
    QCOMPARE(lineTexts(session.lines()), QStringList{QStringLiteral("B 的词")});
}

void LyricsSessionTests::testCancelledLoadResetsLoading()
{
    StubMusicProvider provider;
    provider.lyricsHandler = [](const QString&, CancellationToken ct) -> Task<LyricResult> {
        co_await Delay(60000, ct);
        co_return LyricResult{};
    };
    LyricsSession session([&provider](const Song&) { return &provider; });

    Song song = makeSong(QStringLiteral("1"));
    CancellationTokenSource cts;
    auto task = session.loadAsync(&song, cts.token());
    task.start();
    QVERIFY(session.isLoading());

    cts.cancel();
    QVERIFY2(until([&] { return task.isDone(); }), "取消后加载未结束");

    QVERIFY(!session.isLoading());
    QVERIFY(!session.errorMessage().has_value());
}

void LyricsSessionTests::testResetClearsEverythingSynchronously()
{
    StubMusicProvider provider;
    provider.lyricsHandler = [](const QString&, CancellationToken) {
        LyricResult result;
        result.lines = {line(0, QStringLiteral("A 的词"))};
        result.hasWordTiming = true;
        result.isPureMusic = true;
        return makeReadyTask(result);
    };
    LyricsSession session([&provider](const Song&) { return &provider; });
    Song song = makeSong(QStringLiteral("A"));
    syncWait(session.loadAsync(&song));
    QVERIFY(!session.lines().isEmpty());
    QVERIFY(session.isPureMusic());
    QVERIFY(session.hasWordTiming());

    session.reset();

    QVERIFY(session.lines().isEmpty());
    QVERIFY(!session.isPureMusic());
    QVERIFY(!session.hasWordTiming());
    QVERIFY(!session.isLoading());
    QVERIFY(!session.errorMessage().has_value());
}

void LyricsSessionTests::testAlreadyCancelledLoadDoesNotClearState()
{
    StubMusicProvider provider;
    provider.lyricsHandler = [](const QString&, CancellationToken) {
        return makeReadyTask(lyricsFrom(QStringLiteral("A 的词")));
    };
    LyricsSession session([&provider](const Song&) { return &provider; });
    Song songA = makeSong(QStringLiteral("A"));
    syncWait(session.loadAsync(&songA));
    QCOMPARE(lineTexts(session.lines()), QStringList{QStringLiteral("A 的词")});

    CancellationTokenSource cts;
    cts.cancel();
    Song songB = makeSong(QStringLiteral("B"));
    syncWait(session.loadAsync(&songB, cts.token()));

    QCOMPARE(lineTexts(session.lines()), QStringList{QStringLiteral("A 的词")});
    QCOMPARE(provider.lyricRequests.size(), 1);
}

QTEST_MAIN(LyricsSessionTests)
#include "tst_lyrics_session.moc"
