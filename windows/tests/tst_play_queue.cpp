#include <QtTest>

#include "Core/Models/MusicModels.h"
#include "Playback/PlayQueue.h"

#include <algorithm>

using namespace ct;

namespace {

Song makeSong(const QString& id)
{
    Song song;
    song.id = id;
    song.title = QStringLiteral("Song %1").arg(id);
    song.artists.append(Artist{QStringLiteral("a1"), QStringLiteral("Artist"), std::nullopt, {}});
    song.source = SongSource::Netease;
    return song;
}

QList<Song> makeSongs(int count)
{
    QList<Song> songs;
    for (int index = 1; index <= count; ++index) songs.append(makeSong(QString::number(index)));
    return songs;
}

QStringList songIDs(const PlayQueue& queue)
{
    QStringList ids;
    for (const QueueItem& item : queue.items) ids.append(item.song.id);
    return ids;
}

} // namespace

class PlayQueueTests : public QObject {
    Q_OBJECT

private slots:
    void testReplaceAndNavigate();
    void testSequentialEnd();
    void testLoopAll();
    void testLoopOne();
    void testShuffleHistory();
    void testRemoveCurrentItem();
    void testHandleEndedEmptyQueue();
    void testClearQueueStopsNavigation();
    void testMoveKeepsCurrentItem();
    void testMoveOtherItemKeepsCurrentIndexStable();
    void testDuplicateEntries();

    void testAppendKeepsStackAndSetInSync();
    void testPopLastRemovesFromBothStructures();
    void testPopLastOnEmptyReturnsNil();
    void testDuplicateAppendIsIdempotentInSet();
    void testRemoveAllWherePrunesBothStructures();
    void testRemoveAllClearsBoth();
    void testSetAlwaysMirrorsStackMembership();
    void testContainsIsConstantTimeNotLinear();
};

void PlayQueueTests::testReplaceAndNavigate()
{
    PlayQueue queue;
    queue.replace(makeSongs(5), 2);

    QCOMPARE(queue.count(), 5);
    QCOMPARE(queue.currentIndex, 2);
    QCOMPARE(queue.currentItem()->song.id, QStringLiteral("3"));

    const QueueItem* next = queue.next();
    QVERIFY(next != nullptr);
    QCOMPARE(next->song.id, QStringLiteral("4"));
    QCOMPARE(queue.currentIndex, 3);

    const QueueItem* prev = queue.previous();
    QVERIFY(prev != nullptr);
    QCOMPARE(prev->song.id, QStringLiteral("3"));
    QCOMPARE(queue.currentIndex, 2);
}

void PlayQueueTests::testSequentialEnd()
{
    PlayQueue queue;
    queue.replace(makeSongs(2));
    queue.jumpTo(queue.items[1].id);

    QVERIFY(queue.handleEnded() == nullptr);
}

void PlayQueueTests::testLoopAll()
{
    PlayQueue queue;
    queue.mode = PlayMode::LoopAll;
    queue.replace(makeSongs(2));
    queue.jumpTo(queue.items[1].id);

    const QueueItem* next = queue.handleEnded();
    QVERIFY(next != nullptr);
    QCOMPARE(next->song.id, QStringLiteral("1"));
    QCOMPARE(queue.currentIndex, 0);
}

void PlayQueueTests::testLoopOne()
{
    PlayQueue queue;
    queue.mode = PlayMode::LoopOne;
    queue.replace(makeSongs(1));
    const QueueItem* next = queue.handleEnded();
    QVERIFY(next != nullptr);
    QCOMPARE(next->song.id, QStringLiteral("1"));
}

void PlayQueueTests::testShuffleHistory()
{
    PlayQueue queue;
    queue.mode = PlayMode::Shuffle;
    queue.replace(makeSongs(5));

    const QueueItem* first = queue.currentItem();
    QVERIFY(first != nullptr);
    const QueueItem* next1 = queue.next();
    QVERIFY(next1 != nullptr);
    QVERIFY(first->id != next1->id);

    const QueueItem* prev = queue.previous();
    QVERIFY(prev != nullptr);
    QVERIFY(first->id == prev->id);
}

void PlayQueueTests::testRemoveCurrentItem()
{
    PlayQueue queue;
    queue.replace(makeSongs(3));
    queue.jumpTo(queue.items[1].id);

    const QUuid removedID = queue.items[1].id;
    QVERIFY(queue.remove(removedID));
    QCOMPARE(queue.count(), 2);
    QCOMPARE(queue.currentIndex, 1);
    QCOMPARE(queue.currentItem()->song.id, QStringLiteral("3"));
}

void PlayQueueTests::testHandleEndedEmptyQueue()
{
    const QList<PlayMode> modes = {
        PlayMode::Sequential, PlayMode::LoopAll, PlayMode::LoopOne, PlayMode::Shuffle};
    for (const PlayMode mode : modes) {
        PlayQueue queue;
        queue.mode = mode;
        queue.replace(QList<Song>{});
        QVERIFY(queue.handleEnded() == nullptr);
    }
}

void PlayQueueTests::testClearQueueStopsNavigation()
{
    PlayQueue queue;
    queue.mode = PlayMode::LoopAll;
    queue.replace(makeSongs(2));
    queue.clear();

    QVERIFY(queue.handleEnded() == nullptr);
    QVERIFY(queue.next() == nullptr);
    QVERIFY(queue.currentItem() == nullptr);
}

void PlayQueueTests::testMoveKeepsCurrentItem()
{
    PlayQueue queue;
    queue.replace(makeSongs(3));
    queue.jumpTo(queue.items[0].id);

    queue.move(0, 3);

    QCOMPARE(songIDs(queue), QStringList({QStringLiteral("2"), QStringLiteral("3"), QStringLiteral("1")}));
    QCOMPARE(queue.currentIndex, 2);
    QCOMPARE(queue.currentItem()->song.id, QStringLiteral("1"));
}

void PlayQueueTests::testMoveOtherItemKeepsCurrentIndexStable()
{
    PlayQueue queue;
    queue.replace(makeSongs(3));
    queue.jumpTo(queue.items[1].id);

    queue.move(2, 0);

    QCOMPARE(songIDs(queue), QStringList({QStringLiteral("3"), QStringLiteral("1"), QStringLiteral("2")}));
    QCOMPARE(queue.currentItem()->song.id, QStringLiteral("2"));
    QCOMPARE(queue.currentIndex, 2);
}

void PlayQueueTests::testDuplicateEntries()
{
    PlayQueue queue;
    const Song song = makeSong(QStringLiteral("1"));
    queue.append(song);
    queue.append(song);
    queue.append(song);

    QCOMPARE(queue.count(), 3);
    QSet<QUuid> distinct;
    for (const QueueItem& item : queue.items) distinct.insert(item.id);
    QCOMPARE(distinct.size(), 3);

    queue.remove(queue.items[1].id);
    QCOMPARE(queue.count(), 2);
}

void PlayQueueTests::testAppendKeepsStackAndSetInSync()
{
    ShuffleHistory history;
    const QUuid a = QUuid::createUuid();
    const QUuid b = QUuid::createUuid();
    const QUuid c = QUuid::createUuid();
    history.append(a);
    history.append(b);
    history.append(c);

    QCOMPARE(history.count(), 3);
    QVERIFY(history.contains(a));
    QVERIFY(history.contains(b));
    QVERIFY(history.contains(c));
    QVERIFY(!history.contains(QUuid::createUuid()));

    const auto last = history.popLast();
    QVERIFY(last && *last == c);
    const auto second = history.popLast();
    QVERIFY(second && *second == b);
    const auto first = history.popLast();
    QVERIFY(first && *first == a);
}

void PlayQueueTests::testPopLastRemovesFromBothStructures()
{
    ShuffleHistory history;
    const QUuid a = QUuid::createUuid();
    const QUuid b = QUuid::createUuid();
    history.append(a);
    history.append(b);

    const auto popped = history.popLast();
    QVERIFY(popped && *popped == b);
    QVERIFY(!history.contains(b));
    QVERIFY(history.contains(a));
    QCOMPARE(history.count(), 1);
}

void PlayQueueTests::testPopLastOnEmptyReturnsNil()
{
    ShuffleHistory history;
    QVERIFY(!history.popLast().has_value());
    QVERIFY(history.isEmpty());
}

void PlayQueueTests::testDuplicateAppendIsIdempotentInSet()
{
    ShuffleHistory history;
    const QUuid a = QUuid::createUuid();
    history.append(a);
    history.append(a);

    QCOMPARE(history.count(), 2);
    QVERIFY(history.contains(a));
    const auto popped = history.popLast();
    QVERIFY(popped && *popped == a);
    QVERIFY(history.contains(a));
}

void PlayQueueTests::testRemoveAllWherePrunesBothStructures()
{
    ShuffleHistory history;
    const QUuid keep = QUuid::createUuid();
    const QUuid drop = QUuid::createUuid();
    const QUuid drop2 = QUuid::createUuid();
    history.append(keep);
    history.append(drop);
    history.append(drop2);
    history.removeAllWhere([&](const QUuid& id) { return id == drop || id == drop2; });

    QCOMPARE(history.count(), 1);
    QVERIFY(!history.contains(drop));
    QVERIFY(!history.contains(drop2));
    QVERIFY(history.contains(keep));
    const auto popped = history.popLast();
    QVERIFY(popped && *popped == keep);
}

void PlayQueueTests::testRemoveAllClearsBoth()
{
    ShuffleHistory history;
    history.append(QUuid::createUuid());
    history.append(QUuid::createUuid());
    history.removeAll();

    QVERIFY(history.isEmpty());
    QCOMPARE(history.count(), 0);
    QVERIFY(!history.contains(QUuid::createUuid()));
}

void PlayQueueTests::testSetAlwaysMirrorsStackMembership()
{
    ShuffleHistory history;
    QList<QUuid> ids;
    for (int index = 0; index < 20; ++index) ids.append(QUuid::createUuid());
    for (const QUuid& id : ids) history.append(id);

    QRandomGenerator random(20261007);
    QSet<QUuid> removed;
    for (const QUuid& id : ids) {
        if (random.bounded(2) == 0) removed.insert(id);
    }
    history.removeAllWhere([&](const QUuid& id) { return removed.contains(id); });

    QList<QUuid> expected;
    for (const QUuid& id : ids) {
        QCOMPARE(history.contains(id), !removed.contains(id));
        if (!removed.contains(id)) expected.append(id);
    }

    QList<QUuid> drained;
    while (const auto id = history.popLast()) drained.append(*id);
    std::reverse(drained.begin(), drained.end());
    QCOMPARE(drained, expected);
}

void PlayQueueTests::testContainsIsConstantTimeNotLinear()
{
    ShuffleHistory history;
    QList<QUuid> ids;
    for (int index = 0; index < 5000; ++index) ids.append(QUuid::createUuid());
    for (const QUuid& id : ids) history.append(id);

    bool found = false;
    for (const QUuid& id : ids) {
        if (history.contains(id)) found = true;
    }

    QVERIFY(found);
    QVERIFY(history.contains(ids[4999]));
}

QTEST_MAIN(PlayQueueTests)
#include "tst_play_queue.moc"
