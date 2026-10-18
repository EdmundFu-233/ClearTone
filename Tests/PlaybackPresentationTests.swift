import XCTest
@testable import ClearTone

final class PlaybackPresentationTests: XCTestCase {
    func testMalformedTimesCannotCrashFormatting() {
        for time in [Double.nan, .infinity, -.infinity, -.greatestFiniteMagnitude, .greatestFiniteMagnitude, Double(Int.max)] {
            XCTAssertEqual(PlaybackPresentation.timeLabel(time), "0:00")
        }
    }
    func testClockShowsElapsedMinutesWithoutRoundingForward() {
        XCTAssertEqual(PlaybackPresentation.timeLabel(59.99), "0:59")
        XCTAssertEqual(PlaybackPresentation.timeLabel(3601), "60:01")
    }
    func testUnknownDurationProducesValidSliderRange() {
        for duration in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertEqual(PlaybackPresentation.seekLimit(duration), 1)
        }
    }
    func testSeekPreviewStaysWithinTrack() {
        XCTAssertEqual(PlaybackPresentation.position(.nan, duration: 120), 0)
        XCTAssertEqual(PlaybackPresentation.position(-5, duration: 120), 0)
        XCTAssertEqual(PlaybackPresentation.position(300, duration: 120), 120)
        XCTAssertEqual(PlaybackPresentation.position(30.5, duration: 120), 30.5)
    }
}
