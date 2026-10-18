import Foundation

/// 启动恢复播放进度时的取舍。
///
/// 设置页的「启动时保留上次播放进度」**关闭时必须从头播放** ——
/// 原实现只把这个开关用于「要不要在启动时把 item 挂上播放器」，用户之后手动
/// 点播放时仍然从保存的位置续播，开关语义形同虚设（与设置说明也矛盾）。
/// 与 Windows 版 `setCurrentTime(restorePosition ? data->currentTime : 0)` 对齐。
enum PlaybackRestorePolicy {
    /// 返回恢复播放时应使用的起始进度。
    ///
    /// - Parameters:
    ///   - saved: 队列文件里保存的进度
    ///   - restorePosition: 设置页开关
    static func restoredPosition(saved: TimeInterval, restorePosition: Bool) -> TimeInterval {
        guard restorePosition, saved.isFinite, saved >= 0 else { return 0 }
        return saved
    }
}
