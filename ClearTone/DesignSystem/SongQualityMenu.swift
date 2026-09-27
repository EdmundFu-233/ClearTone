import SwiftUI

/// 「单曲音质」菜单：给当前这首歌点名一个网易音质。
///
/// 存在的原因：本地缓存是 96kbps OPUS（比标准档还低），默认吃缓存图的是秒开；
/// 但想认真听无损时必须能显式地说「这首走网易源、用无损」，
/// 否则设了无损也会在第二次播放被缓存降级。
///
/// 三个入口共用这一个视图：macOS 播放栏的音源标签、正在播放页的胶囊、iOS 播放页。
///
/// 样式上刻意去掉 Menu 自带的边框与箭头（macOS 的 Menu 默认会画一个带 bezel 的
/// 按钮外壳 + 自己的下拉箭头）。不去掉的话，播放栏那个固定宽度的状态槽里
/// 会出现「标签 + 一个空壳按钮」两个框，文字被挤成 `OP…`。
struct SongQualityMenu<Content: View>: View {
    @EnvironmentObject private var player: PlayerController
    /// 只对网易云歌曲有意义（本地文件没有音质可选）
    let songID: String
    /// 挂在整个菜单上的说明文字（tooltip）
    var help: String?
    @ViewBuilder var label: () -> Content

    var body: some View {
        Menu {
            ForEach(SongQualityPolicy.selectableLevels, id: \.self) { level in
                Button {
                    player.setQualityOverride(level, for: songID)
                } label: {
                    if player.qualityOverride(for: songID) == level {
                        Label(level.rawValue, systemImage: "checkmark")
                    } else {
                        Text(level.rawValue)
                    }
                }
            }
            Divider()
            Button("跟随全局设置（\(player.requestedQuality.rawValue)）") {
                player.setQualityOverride(nil, for: songID)
            }
            .disabled(player.qualityOverride(for: songID) == nil)
        } label: {
            label()
        }
        .menuOrder(.fixed)
        .modifier(MenuChrome(help: help))
    }
}

/// 去掉 Menu 默认的按钮外壳，并在菜单整体上挂 tooltip
private struct MenuChrome: ViewModifier {
    let help: String?

    func body(content: Content) -> some View {
        content
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .help(help ?? "")
    }
}
