import SwiftUI
import Combine

/// 订阅 `PlayerController.timePublisher` 并把播放进度放进局部 `@State`。
///
/// 存在的理由：`PlayerController` 是 ObservableObject，而 SwiftUI 对它只有
/// 「合并后的 objectWillChange」这一种订阅粒度（属性级追踪只有 `@Observable` 才有）。
/// 若把 `currentTime` 放在 `@Published` 上，2Hz 的进度更新会让所有
/// `@EnvironmentObject` 持有者的整个 body 重算 —— 包括侧栏、队列面板、
/// Metal 背景、歌词列表的 ForEach 差分，而这些重算 100% 不产生可见变化。
///
/// 用法：把依赖 currentTime 的部分包进这个 ViewModifier，
/// 只有它自己会被重算。
struct PlaybackTimeObserver<Content: View>: View {
    let player: PlayerController
    @ViewBuilder var content: (TimeInterval) -> Content

    @State private var time: TimeInterval = 0

    var body: some View {
        content(time)
            .onReceive(player.timePublisher) { time = $0 }
            .onAppear { time = player.currentTime }
            // 切歌时 duration/playbackState 会变，借这个已发布的状态补一次同步
            .onChange(of: player.currentSong?.id) { _, _ in
                time = player.currentTime
            }
    }
}

extension View {
    /// 只让 `content` 在播放进度变化时重算
    func observingPlaybackTime(
        _ player: PlayerController,
        @ViewBuilder _ content: @escaping (TimeInterval) -> some View
    ) -> some View {
        PlaybackTimeObserver(player: player, content: content)
    }
}
