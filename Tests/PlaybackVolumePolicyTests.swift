import XCTest
@testable import ClearTone

final class PlaybackVolumePolicyTests: XCTestCase {
    func testIOSLegacyVolumeDoesNotAttenuateOutput() {
        // 旧版本默认 0.8；即使保存过更低的值或 0，系统音量也应能正常控制。
        for stored: Float in [0, 0.2, 0.8, 1] {
            let output = PlaybackVolumePolicy.output(volume: stored, isMuted: false, platform: .iOS)
            XCTAssertEqual(output.volume, 1)
            XCTAssertFalse(output.isMuted)
        }
    }

    func testIOSLegacyMuteDoesNotOverrideSystemVolume() {
        let output = PlaybackVolumePolicy.output(volume: 0.2, isMuted: true, platform: .iOS)
        XCTAssertEqual(output, .init(volume: 1, isMuted: false))
    }

    func testMacOSPreservesUserVolumeAndMute() {
        for stored: Float in [0, 0.2, 0.8, 1] {
            for muted in [false, true] {
                XCTAssertEqual(PlaybackVolumePolicy.output(volume: stored, isMuted: muted, platform: .macOS), .init(volume: stored, isMuted: muted))
            }
        }
    }

    func testPlatformDefaultAndOutputAgree() {
        #if os(iOS)
        XCTAssertEqual(PlaybackVolumePolicy.defaultVolume, 1)
        XCTAssertEqual(PlaybackVolumePolicy.output(volume: 0.2, isMuted: true), .init(volume: 1, isMuted: false))
        #else
        XCTAssertEqual(PlaybackVolumePolicy.defaultVolume, 0.8)
        XCTAssertEqual(PlaybackVolumePolicy.output(volume: 0.2, isMuted: true), .init(volume: 0.2, isMuted: true))
        #endif
    }
}
