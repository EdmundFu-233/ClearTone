import CoreTransferable
import UniformTypeIdentifiers

/// 拖放载荷。
///
/// 带完整 `Song`，不只带 id。
///
/// 早先只传 `songID`，落到队列时按 id 从「当前队列 + 播放历史」里查回来 ——
/// 于是**从没播放过的搜索结果一拖就丢**：两个来源里都没有它，
/// `resolveSongs` 返回空，drop 回调返回 false，界面上毫无反应。
///
/// 「不要在拖放里塞整个 Song」的理由（跨进程 payload 大、字段变化会解码失败）
/// 在本 App 内的拖放上不成立：编码端与解码端是**同一个运行中进程里的同一份类型**，
/// 一次拖放活不过一次 App 运行。
struct SongTransfer: Codable, Transferable {
    let song: Song

    init(song: Song) { self.song = song }

    var songID: String { song.id }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .cleartoneSong)
    }

    /// 还原拖放带来的歌曲。
    ///
    /// 优先级：本地池（当前队列 + 播放历史）里的同名歌 → 载荷自带的 `Song` 快照。
    /// 反过来优先用本地副本，是为了拿到更完整的对象（比如带 `qualities` 的）。
    /// 载荷一定带得上完整 `Song`，所以搜索结果、榜单、歌单里**从未播放过**的歌也能入队。
    ///
    /// 本地池只作补充，不维护「所有见过的歌」的全局索引：
    /// 那会让内存无界增长（spec §6 明确禁止）。
    /// 同一批里重复的 id 只保留第一次出现的位置。
    static func resolveSongs(_ transfers: [SongTransfer], pool: [Song]) -> [Song] {
        var seen = Set<String>()
        var result: [Song] = []
        for transfer in transfers {
            let song = pool.first { $0.id == transfer.song.id } ?? transfer.song
            guard seen.insert(song.id).inserted else { continue }
            result.append(song)
        }
        return result
    }
}

extension UTType {
    /// 自定义拖放类型。只在本 App 内使用（拖进自己的队列面板），
    /// 因此不需要导出到系统其它 App。
    static let cleartoneSong = UTType(exportedAs: "com.cleartone.song")
}
