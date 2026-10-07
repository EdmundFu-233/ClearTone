import Foundation
import Combine

/// 歌词来源的解析：给定歌曲返回用哪个 Provider 取歌词，返回 nil 表示这首不取。
///
/// 用闭包注入而不是在 session 里直接 `switch song.source`：`Providers/Local`
/// 整个目录**没有编进 iOS target**（iOS 没有桌面端的文件夹导入，本地曲库走
/// `MobileLocalLibrary`），在 Core 里写死 `LocalProvider` 会把 iOS 编译打断。
/// 于是 macOS 在自己的视图里交出「本地 → LocalProvider」，iOS 交出「只走在线」。
public typealias LyricsProviderResolver = @Sendable (Song) -> (any MusicProvider)?

/// 正在播放页的歌词状态机。
///
/// ## 为什么抽到 Core
///
/// macOS 的 `NowPlayingView` 与 iOS 的 `IOSNowPlayingView` 原先**各自手写**
/// 了一份几乎相同的状态机：切歌先同步清空（否则会短暂显示上一首的歌词）、
/// 用歌曲身份校验丢弃迟到的响应、失败要清空而不是留下半截。
/// 两份都写在视图里，而 `project.yml` 把 `Features/**` 和 iOS 视图排除在测试
/// target 之外 —— 一条断言都写不了。抽到这里之后两边共用，且边界可测。
@MainActor
public final class LyricsSession: ObservableObject {

    @Published public private(set) var lines: [LyricLine] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    /// 纯音乐（只有曲没有词）：界面显示「纯音乐，请欣赏」而不是「暂无歌词」
    @Published public private(set) var isPureMusic = false
    /// 是否有逐字时间轴（决定要不要走逐字高亮）
    @Published public private(set) var hasWordTiming = false

    private let resolve: LyricsProviderResolver
    /// 代次令牌：`load` 一进来就换，旧请求回来时对不上就丢弃。
    /// 只靠 `Task.isCancelled` 是不够的 —— 视图用 `.task(id:)`/`onChange` 触发时，
    /// 上一次请求未必来得及被取消（取消不保证在 await 返回前生效）。
    private var token = UUID()

    public init(resolve: @escaping LyricsProviderResolver) {
        self.resolve = resolve
    }

    /// 在线歌词来源：非网易云歌曲不取（本地歌词由各平台自己解析）。
    public static func neteaseOnly() -> LyricsSession {
        LyricsSession { song in song.source == .netease ? NeteaseProvider.shared : nil }
    }

    /// 加载某首歌的歌词。传 nil（没有正在播放的歌）会清空。
    public func load(for song: Song?) async {
        token = UUID()
        let token = self.token
        // 先同步清空：切歌的瞬间旧歌词必须先消失，否则会拿上一首的词配这一首的进度
        lines = []
        isPureMusic = false
        hasWordTiming = false
        errorMessage = nil

        guard let song, let provider = resolve(song) else {
            // 没有歌 / 这首不取歌词：不留 loading，界面走空态
            isLoading = false
            return
        }
        isLoading = true
        // 用 defer 收尾：`.task` 会在视图消失时取消，靠末尾赋值复位的话，
        // 取消路径会让 isLoading 永久停在 true（歌词面板一直转圈）。
        defer { if self.token == token { isLoading = false } }

        do {
            let result = try await provider.fetchLyrics(songID: song.id)
            guard self.token == token, !Task.isCancelled else { return }
            lines = result.lines
            isPureMusic = result.isPureMusic
            hasWordTiming = result.hasWordTiming
        } catch {
            guard self.token == token, !Task.isCancelled else { return }
            // 取消不是「加载失败」：别把用户主动离开页面变成一条错误提示
            if error is CancellationError { return }
            errorMessage = error.ctUserMessage
        }
    }
}
