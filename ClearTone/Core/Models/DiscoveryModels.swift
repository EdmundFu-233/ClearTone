import Foundation

// MARK: - 榜单

/// 网易云榜单（`/toplist`）。榜单本身就是一个歌单，`playlistID` 可直接
/// 喂给 `fetchPlaylistDetail`。
public struct TopList: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var coverURL: URL?
    /// 更新频率文案，如「每天更新」
    public var updateFrequency: String?
    public var trackCount: Int
    public var playCount: Int
    public var descriptionText: String?
    /// 榜单封面上的角标（如「新品首发」）
    public var iconURL: URL?

    public init(id: String, name: String, coverURL: URL? = nil,
                updateFrequency: String? = nil, trackCount: Int = 0,
                playCount: Int = 0, descriptionText: String? = nil,
                iconURL: URL? = nil) {
        self.id = id; self.name = name; self.coverURL = coverURL
        self.updateFrequency = updateFrequency; self.trackCount = trackCount
        self.playCount = playCount; self.descriptionText = descriptionText
        self.iconURL = iconURL
    }
}

/// 新歌速递的地区维度（`/top/song` 的 `areaId`）
public enum TopSongArea: String, CaseIterable, Sendable, Identifiable {
    case all = "全部"
    case chinese = "华语"
    case western = "欧美"
    case japan = "日本"
    case korea = "韩国"

    public var id: String { rawValue }
    /// 接口参数值。与 `interface.d.ts` 的 `TopSongType` 一致。
    public var areaID: Int {
        switch self {
        case .all: return 0
        case .chinese: return 7
        case .western: return 96
        case .japan: return 8
        case .korea: return 16
        }
    }
}

/// 歌单广场排序（`/top/playlist` 的 `order`）
public enum TopPlaylistOrder: String, CaseIterable, Sendable, Identifiable {
    case hot = "最热"
    case new = "最新"

    public var id: String { rawValue }
    public var apiValue: String {
        switch self {
        case .hot: return "hot"
        case .new: return "new"
        }
    }
}

/// 歌单分类分组（`/playlist/catlist`）
///
/// 接口返回 `sub`（热门分类，展示名 → 机器值）与 `categories`（全部分类）。
/// 这里只保留展示需要的结构：分组名 + 该组下的分类名列表。
public struct PlaylistCategoryGroup: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var categories: [String]

    public init(name: String, categories: [String]) {
        self.name = name
        self.categories = categories
    }
}

// MARK: - 搜索辅助

/// 搜索框联想结果。`kind` 决定点击后跳到哪个页面。
public struct SearchSuggestion: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case song, artist, album, playlist
    }

    public var id: String { "\(kind.rawValue)-\(targetID)" }
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var coverURL: URL?
    public var targetID: String

    public init(kind: Kind, title: String, subtitle: String? = nil,
                coverURL: URL? = nil, targetID: String) {
        self.kind = kind; self.title = title; self.subtitle = subtitle
        self.coverURL = coverURL; self.targetID = targetID
    }
}

/// 热搜词。`score` 是热度值，接口不保证返回，缺失时为 0。
public struct HotSearchTerm: Identifiable, Hashable, Sendable {
    public var id: String { keyword }
    public var keyword: String
    public var score: Int
    /// 展示前缀（接口的 `firstword`，通常与 keyword 首字重复）
    public var displayPrefix: String?
    /// 角标图标（emoji）
    public var icon: String?

    public init(keyword: String, score: Int = 0,
                displayPrefix: String? = nil, icon: String? = nil) {
        self.keyword = keyword; self.score = score
        self.displayPrefix = displayPrefix; self.icon = icon
    }
}

// MARK: - 账号数据

/// 听歌等级（`/user/level`）
public struct UserLevelInfo: Hashable, Sendable {
    public var level: Int
    public var listenSongs: Int
    public var listenDays: Int
    public var currentLoginDays: Int
    public var nextLevelNeedLoginDays: Int
    public var nextLevelNeedListenSongs: Int
    public var currentProgress: Int

    public init(level: Int, listenSongs: Int, listenDays: Int,
                currentLoginDays: Int, nextLevelNeedLoginDays: Int,
                nextLevelNeedListenSongs: Int, currentProgress: Int) {
        self.level = level; self.listenSongs = listenSongs
        self.listenDays = listenDays; self.currentLoginDays = currentLoginDays
        self.nextLevelNeedLoginDays = nextLevelNeedLoginDays
        self.nextLevelNeedListenSongs = nextLevelNeedListenSongs
        self.currentProgress = currentProgress
    }

    /// 距下一级还差多少天（0 表示已满级或接口未给数据）
    public var remainingLoginDays: Int { max(0, nextLevelNeedLoginDays) }

    /// 升级进度 0...1。
    ///
    /// `nextLevelNeedLoginDays == 0` 表示**已满级**（或接口没给数据），
    /// 此时必须返回 0 而不是拿 `max(0, 1)` 当分母算出 1.0 ——
    /// 那会让满级用户的进度条显示成「已完成」。
    public var progressFraction: Double {
        guard nextLevelNeedLoginDays > 0 else { return 0 }
        return min(1, max(0, Double(currentLoginDays) / Double(nextLevelNeedLoginDays)))
    }
}

/// 听歌记录条目（`/user/record`）
public struct ListenRecord: Identifiable, Hashable, Sendable {
    public var id: String { song.id }
    public var song: Song
    /// 播放次数（接口的 `score`）
    public var playCount: Int
    /// 最后一次播放时间
    public var lastPlayedAt: Date?

    public init(song: Song, playCount: Int, lastPlayedAt: Date? = nil) {
        self.song = song; self.playCount = playCount; self.lastPlayedAt = lastPlayedAt
    }
}

/// 签到结果（`/daily_signin`）
public enum SignInResult: Sendable, Equatable {
    /// 签到成功，`point` 是本次获得的成长值
    case success(point: Int)
    /// 今天已经签过
    case alreadySigned
    case failed(String)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - 订阅状态

/// 收藏目标。`targetID` 是网易云的 id，`kind` 决定调哪个接口。
public enum SubscribeTarget: Hashable, Sendable {
    case playlist(String)
    case album(String)
    case artist(String)
    case radio(String)

    public var id: String {
        switch self {
        case .playlist(let v), .album(let v), .artist(let v), .radio(let v): return v
        }
    }

    public var displayName: String {
        switch self {
        case .playlist: return "歌单"
        case .album: return "专辑"
        case .artist: return "歌手"
        case .radio: return "电台"
        }
    }

    /// `fetchUserCounts` 返回的计数字典键（与 `displayName` 不同）。
    /// 上游没有专辑计数，`.album` 返回 nil。
    public var countKey: String? {
        switch self {
        case .playlist: return "收藏歌单"
        case .album: return nil
        case .artist: return "关注歌手"
        case .radio: return "收藏电台"
        }
    }
}
