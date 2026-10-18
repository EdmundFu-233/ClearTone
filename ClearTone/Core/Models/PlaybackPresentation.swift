import Foundation

enum PlaybackPresentation {
    static func timeLabel(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let value = Int(seconds)
        return "\(value / 60):" + String(format: "%02d", value % 60)
    }

    static func seekLimit(_ duration: TimeInterval) -> TimeInterval {
        duration.isFinite && duration > 0 ? duration : 1
    }

    static func position(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        return min(max(0, time), seekLimit(duration))
    }
}
