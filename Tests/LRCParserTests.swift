import XCTest

final class LRCParserTests: XCTestCase {

    func testBasicLRC() {
        let lrc = """
        [00:01.00]第一行
        [00:05.50]第二行
        [00:10.00]第三行
        """
        let lines = LRCParser.parse(lrc)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].time, 1.0)
        XCTAssertEqual(lines[1].time, 5.5)
        XCTAssertEqual(lines[0].text, "第一行")
    }

    func testDuplicateTimestamps() {
        // 重复时间戳会被合并（后者覆盖前者），这是预期行为
        let lrc = """
        [00:01.00]同一时间
        [00:01.00]重复时间
        [00:02.00]下一行
        """
        let lines = LRCParser.parse(lrc)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "重复时间") // 后者覆盖
        XCTAssertEqual(lines[1].text, "下一行")
    }

    func testMalformedLines() {
        let lrc = """
        [invalid]无效行
        [00:01.00]正常行
        []
        [00:02.00]
        """
        let lines = LRCParser.parse(lrc)
        XCTAssertEqual(lines.count, 2) // 只有两行有效
    }

    func testTranslationMerge() {
        let lrc = "[00:01.00]你好"
        let trans = "[00:01.00]Hello"
        let lines = LRCParser.parse(lrc, translation: trans)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].translation, "Hello")
    }

    func testBinarySearch() {
        let lines = [
            LyricLine(time: 1.0, text: "a"),
            LyricLine(time: 5.0, text: "b"),
            LyricLine(time: 10.0, text: "c"),
            LyricLine(time: 20.0, text: "d"),
        ]

        XCTAssertEqual(LRCParser.currentLineIndex(in: lines, at: 0), nil)
        XCTAssertEqual(LRCParser.currentLineIndex(in: lines, at: 1.0), 0)
        XCTAssertEqual(LRCParser.currentLineIndex(in: lines, at: 3.0), 0)
        XCTAssertEqual(LRCParser.currentLineIndex(in: lines, at: 5.0), 1)
        XCTAssertEqual(LRCParser.currentLineIndex(in: lines, at: 15.0), 2)
        XCTAssertEqual(LRCParser.currentLineIndex(in: lines, at: 25.0), 3)
    }

    func testBinarySearchWithOffset() {
        let lines = [
            LyricLine(time: 5.0, text: "a"),
            LyricLine(time: 10.0, text: "b"),
        ]

        // 偏移 -2 秒：实际时间 7 秒对应歌词时间 5 秒
        XCTAssertEqual(LRCParser.currentLineIndex(in: lines, at: 7.0, offset: -2.0), 0)
        // 偏移 +2 秒：实际时间 3 秒对应歌词时间 5 秒
        XCTAssertEqual(LRCParser.currentLineIndex(in: lines, at: 3.0, offset: 2.0), 0)
    }

    func testYRC() {
        let yrc = "[0,1000]我(0,200,0)们(200,300,0)"
        let lines = LRCParser.parseYRC(yrc)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].words?.count, 2)
        XCTAssertEqual(lines[0].text, "我们")
    }
}
