import SwiftUI

/// 移动端共享的语义色与间距；跟随系统深浅色和辅助功能设置。
enum IOSTheme {
    static let accent = Color.indigo
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let radius: CGFloat = 22
}

struct IOSCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(20).background(IOSTheme.surface, in: RoundedRectangle(cornerRadius: IOSTheme.radius))
    }
}

extension View {
    func iosCard() -> some View { modifier(IOSCard()) }
}

struct IOSSectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.bold()).foregroundStyle(.primary)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

struct IOSPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14).padding(.horizontal, 18)
            .foregroundStyle(.white).background(IOSTheme.accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// 写操作被服务端限流时的提示。
///
/// 网易云的写接口一旦触发风控（`/like` 回 524、`/playlist/*` 回 405），
/// 所有写接口会一起挂，App 进入 30 秒冷却期，期间心形**连请求都不发**。
/// 不解释的话，用户看到的就是「按钮点不动、也没有任何反应」——
/// macOS 侧一直有这条提示，iOS 侧原先完全没读这几个属性。
struct IOSWriteCooldownNotice: View {
    let remaining: Int
    let message: String?

    var body: some View {
        if remaining > 0 {
            Label(
                message.map { "\($0)（约 \(remaining) 秒后可再试）" } ?? "操作过于频繁，约 \(remaining) 秒后可再试",
                systemImage: "hourglass"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct IOSPlaylistCard: View {
    let playlist: Playlist
    var body: some View {
        NavigationLink { IOSCollectionView(kind: .playlist(playlist.id)) } label: {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { proxy in IOSCover(url: playlist.coverURL, size: proxy.size.width, cornerRadius: 18) }
                    .aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
                Text(playlist.name).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true).foregroundStyle(.primary)
                Text(playlist.creatorName ?? "网易云音乐").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityElement(children: .combine).accessibilityHint("打开歌单")
    }
}
