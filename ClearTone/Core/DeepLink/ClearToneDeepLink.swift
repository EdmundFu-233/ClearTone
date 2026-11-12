import Foundation

/// 主 App 与桌面 Widget 共用的 deep link。
///
/// Widget 扩展拿不到主 App 的沙盒数据（没有 App Group），能做的只有「点一下，
/// 把 App 打开到对应位置」。所以跳转目标必须同时被两边编译：这里只依赖
/// Foundation，Widget target 会直接把这份文件加进自己的 sources。
public enum ClearToneDeepLink: String, CaseIterable, Sendable {
    case discover
    case search
    case library
    case nowPlaying = "now-playing"
    case settings

    public static let scheme = "cleartone"

    /// 用于 `Link(destination:)` / `.widgetURL(_:)`。
    public var url: URL {
        // scheme 与 rawValue 都是编译期常量，这里不可能构造失败。
        URL(string: "\(Self.scheme)://\(rawValue)")!
    }

    /// 同时接受 `cleartone://search` 与 `cleartone:///search`。
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let raw = url.host?.lowercased()
            ?? url.pathComponents.dropFirst().first?.lowercased()
        guard let raw, let link = Self(rawValue: raw) else { return nil }
        self = link
    }
}
