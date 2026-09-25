import XCTest

final class PlayQueueTests: XCTestCase {

    private func makeSong(id: String) -> Song {
        Song(id: id, title: "Song \(id)", artists: [Artist(id: "a1", name: "Artist")], source: .demo)
    }

    func testReplaceAndNavigate() {
        var queue = PlayQueue()
        let songs = (1...5).map { makeSong(id: "\($0)") }
        queue.replace(with: songs, startAt: 2)

        XCTAssertEqual(queue.count, 5)
        XCTAssertEqual(queue.currentIndex, 2)
        XCTAssertEqual(queue.currentItem?.song.id, "3")

        // next
        let next = queue.next()
        XCTAssertEqual(next?.song.id, "4")
        XCTAssertEqual(queue.currentIndex, 3)

        // previous
        let prev = queue.previous()
        XCTAssertEqual(prev?.song.id, "3")
        XCTAssertEqual(queue.currentIndex, 2)
    }

    func testSequentialEnd() {
        var queue = PlayQueue()
        queue.replace(with: [makeSong(id: "1"), makeSong(id: "2")])
        queue.jumpTo(itemID: queue.items[1].id)

        // 最后一首结束
        let next = queue.handleEnded()
        XCTAssertNil(next)
    }

    func testLoopAll() {
        var queue = PlayQueue()
        queue.mode = .loopAll
        queue.replace(with: [makeSong(id: "1"), makeSong(id: "2")])
        queue.jumpTo(itemID: queue.items[1].id)

        let next = queue.handleEnded()
        XCTAssertEqual(next?.song.id, "1")
        XCTAssertEqual(queue.currentIndex, 0)
    }

    func testLoopOne() {
        var queue = PlayQueue()
        queue.mode = .loopOne
        queue.replace(with: [makeSong(id: "1")])
        let next = queue.handleEnded()
        XCTAssertEqual(next?.song.id, "1")
    }

    func testShuffleHistory() {
        var queue = PlayQueue()
        queue.mode = .shuffle
        queue.replace(with: (1...5).map { makeSong(id: "\($0)") })

        let first = queue.currentItem
        let next1 = queue.next()
        XCTAssertNotNil(next1)
        XCTAssertNotEqual(next1?.id, first?.id)

        // previous 应回到实际听过的曲目
        let prev = queue.previous()
        XCTAssertEqual(prev?.id, first?.id)
    }

    func testRemoveCurrentItem() {
        var queue = PlayQueue()
        queue.replace(with: [makeSong(id: "1"), makeSong(id: "2"), makeSong(id: "3")])
        queue.jumpTo(itemID: queue.items[1].id)

        let removedID = queue.items[1].id
        XCTAssertTrue(queue.remove(itemID: removedID))
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.currentIndex, 1)
        XCTAssertEqual(queue.currentItem?.song.id, "3")
    }

    func testHandleEndedEmptyQueue() {
        // 回归：空队列下任意模式 handleEnded 不得崩溃（取余除零）
        for mode in PlayMode.allCases {
            var queue = PlayQueue()
            queue.mode = mode
            queue.replace(with: [])
            let next = queue.handleEnded()
            XCTAssertNil(next, "mode=\(mode)")
        }
    }

    func testClearQueueStopsNavigation() {
        var queue = PlayQueue()
        queue.mode = .loopAll
        queue.replace(with: [makeSong(id: "1"), makeSong(id: "2")])
        queue.clear()

        XCTAssertNil(queue.handleEnded())
        XCTAssertNil(queue.next())
        XCTAssertNil(queue.currentItem)
    }

    func testMoveKeepsCurrentItem() {
        var queue = PlayQueue()
        queue.replace(with: [makeSong(id: "1"), makeSong(id: "2"), makeSong(id: "3")])
        queue.jumpTo(itemID: queue.items[0].id)

        // 把第 1 项（当前）拖到最后
        queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        XCTAssertEqual(queue.items.map(\.song.id), ["2", "3", "1"])
        XCTAssertEqual(queue.currentIndex, 2)
        XCTAssertEqual(queue.currentItem?.song.id, "1")
    }

    func testMoveOtherItemKeepsCurrentIndexStable() {
        var queue = PlayQueue()
        queue.replace(with: [makeSong(id: "1"), makeSong(id: "2"), makeSong(id: "3")])
        queue.jumpTo(itemID: queue.items[1].id)

        // 当前条目（index 1）不受影响时，只移动第 3 项到第 1 项前
        queue.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(queue.items.map(\.song.id), ["3", "1", "2"])
        XCTAssertEqual(queue.currentItem?.song.id, "2")
        XCTAssertEqual(queue.currentIndex, 2)
    }

    func testDuplicateEntries() {
        var queue = PlayQueue()
        let song = makeSong(id: "1")
        queue.append(song)
        queue.append(song)
        queue.append(song)

        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(Set(queue.items.map(\.id)).count, 3) // 独立 ID

        // 移除第二个
        let secondID = queue.items[1].id
        queue.remove(itemID: secondID)
        XCTAssertEqual(queue.count, 2)
    }
}
