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
/// 用法：把**依赖 currentTime 的那部分内容**放进 `observingPlaybackTime` 的闭包，
/// 只有它自己会被重算。
///
/// ## 注意：它**不是** ViewModifier，`self` 会被丢弃
///
/// `func observingPlaybackTime(...) -> some View` 返回的是一个全新视图，
/// 接收者 `self` 从未参与。写成
/// ```swift
/// someView.observingPlaybackTime(player) { time in ... }
/// ```
/// 的话，`someView` **不会**被替换掉，而是和闭包内容**同时渲染**。
///
/// 历史上 `NowPlayingView` 因此渲染了两条进度条：一条时间恒为 0:00（但仍是
/// 可拖动的真 Slider，拖它会走 previewSeek/commitSeek 而立刻弹回 0）。
/// 正确写法是把内容只放进闭包，不要写在接收者位置上。
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
    /// 只让 `content` 在播放进度变化时重算。
    ///
    /// **返回的是全新视图，接收者 `self` 被丢弃** —— 写在接收者位置上的内容
    /// 会和闭包内容同时渲染（见上面的说明）。内容只放进闭包。
    func observingPlaybackTime(
        _ player: PlayerController,
        @ViewBuilder _ content: @escaping (TimeInterval) -> some View
    ) -> some View {
        PlaybackTimeObserver(player: player, content: content)
    }
}
