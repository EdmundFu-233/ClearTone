import Foundation

/// iOS 用系统媒体音量；macOS 保留应用内音量和静音控制。
/// 手机 UI 的 MPVolumeView 不会修改 AVPlayer.volume，不能再叠加桌面音量衰减。
enum PlaybackVolumePolicy {
    enum Platform: Sendable { case iOS, macOS }
    struct Output: Equatable, Sendable {
        let volume: Float
        let isMuted: Bool
    }

    static var platform: Platform {
        #if os(iOS)
        .iOS
        #else
        .macOS
        #endif
    }

    static var defaultVolume: Float { platform == .iOS ? 1 : 0.8 }

    /// 同时用于旧状态恢复、播放器首次创建/复用和运行中设置变化。
    /// iOS 无应用内静音入口，旧快照的 mute 也不能阻断系统音量控制。
    static func output(volume: Float, isMuted: Bool, platform: Platform = platform) -> Output {
        switch platform {
        case .iOS: Output(volume: 1, isMuted: false)
        case .macOS: Output(volume: volume, isMuted: isMuted)
        }
    }
}
