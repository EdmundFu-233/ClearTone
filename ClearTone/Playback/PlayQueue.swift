import Foundation
import AVFoundation

/// 播放状态，区分用户意图与系统状态
public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading(songID: String)
    case playing(songID: String)
    case paused(songID: String)
    case buffering(songID: String)
    case ended(songID: String)
    case failed(songID: String, reason: String)

    public var songID: String? {
        switch self {
        case .idle: return nil
        case .loading(let id), .playing(let id), .paused(let id), .buffering(let id), .ended(let id), .failed(let id, _): return id
        }
    }

    public var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    /// 用户的播放意图：缓冲中虽然此刻没在出声，但意图仍是「播放中」，
    /// 所以播放按钮应继续显示暂停图标，否则会在缓冲的瞬间跳成 ▶，看着像被暂停了。
    public var isPlayIntentActive: Bool {
        switch self {
        case .playing, .buffering, .loading: return true
        default: return false
        }
    }

    /// 是否处于缓冲中（网络抖动、需要等待数据）
    public var isBuffering: Bool {
        if case .buffering = self { return true }
        return false
    }
}

/// 播放模式
public enum PlayMode: String, CaseIterable, Sendable, Codable {
    case sequential = "顺序播放"
    case loopAll = "列表循环"
    case loopOne = "单曲循环"
    case shuffle = "随机播放"
}

/// 队列条目，使用独立稳定 ID 支持同一首歌重复加入
public struct QueueItem: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public var song: Song
    public var addedAt: Date

    public init(id: UUID = UUID(), song: Song, addedAt: Date = Date()) {
        self.id = id; self.song = song; self.addedAt = addedAt
    }

    public static func == (lhs: QueueItem, rhs: QueueItem) -> Bool { lhs.id == rhs.id }
}

/// 播放队列状态机
public struct PlayQueue: Sendable, Codable {
    public internal(set) var items: [QueueItem] = []
    public internal(set) var currentIndex: Int = -1
    public var mode: PlayMode = .sequential

    /// 随机模式历史：既是「上一首」的 LIFO 回退栈，又是「已播过」的 O(1) 判定集合。
    ///
    /// 原先只用 `[UUID]`，`contains` 是线性扫描，随机模式的 next() 变成 O(n×k)，
    /// 1000 首时单次调用约 10⁶ 次 UUID 比较。封装成类型是为了保证栈与集合不会失同步。
    struct ShuffleHistory: Codable {
        private(set) var stack: [UUID] = []
        private var set: Set<UUID> = []

        var isEmpty: Bool { stack.isEmpty }
        var count: Int { stack.count }

        mutating func append(_ id: UUID) {
            stack.append(id)
            set.insert(id)
        }

        /// 取出最近播过的一首（LIFO）
        ///
        /// 注意：同一个 id 可能重复入栈（随机模式回绕时会再次播放同一首），
        /// 所以只有当栈里已经不再有该 id 时才能从集合移除，
        /// 否则会出现「栈里还有记录、集合里已删除」的失同步，
        /// 导致该歌在应该被排除时被重复抽中。
        mutating func popLast() -> UUID? {
            guard let id = stack.popLast() else { return nil }
            if !stack.contains(id) { set.remove(id) }
            return id
        }

        func contains(_ id: UUID) -> Bool { set.contains(id) }

        mutating func removeAll() {
            stack.removeAll()
            set.removeAll()
        }

        mutating func removeAll(where shouldRemove: (UUID) -> Bool) {
            stack.removeAll(where: shouldRemove)
            set = Set(stack)
        }
    }

    /// 随机模式历史栈（存储 item id），用于上一首回退
    private var shuffleHistory = ShuffleHistory()

    public init() {}

    public var currentItem: QueueItem? {
        guard currentIndex >= 0, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public var hasNext: Bool {
        guard !items.isEmpty else { return false }
        switch mode {
        case .loopOne: return true
        case .loopAll: return !items.isEmpty
        case .sequential: return currentIndex < items.count - 1
        case .shuffle: return !items.isEmpty
        }
    }

    public var hasPrevious: Bool {
        guard !items.isEmpty else { return false }
        switch mode {
        case .loopOne: return true
        case .shuffle: return !shuffleHistory.isEmpty
        default: return currentIndex > 0
        }
    }

    // MARK: - 变更操作

    public mutating func replace(with songs: [Song], startAt index: Int = 0) {
        items = songs.map { QueueItem(song: $0) }
        currentIndex = items.isEmpty ? -1 : max(0, min(index, items.count - 1))
        shuffleHistory.removeAll()
    }

    public mutating func append(_ song: Song) {
        items.append(QueueItem(song: song))
        if currentIndex == -1 { currentIndex = 0 }
    }

    public mutating func append(contentsOf songs: [Song]) {
        items.append(contentsOf: songs.map { QueueItem(song: $0) })
        if currentIndex == -1 { currentIndex = 0 }
    }

    public mutating func insertNext(_ song: Song) {
        let item = QueueItem(song: song)
        if currentIndex == -1 {
            items.append(item)
            currentIndex = 0
        } else {
            items.insert(item, at: currentIndex + 1)
        }
    }

    @discardableResult
    public mutating func remove(itemID: UUID) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return false }
        items.remove(at: idx)
        shuffleHistory.removeAll { $0 == itemID }
        if idx < currentIndex {
            currentIndex -= 1
        } else if idx == currentIndex {
            if currentIndex >= items.count { currentIndex = items.count - 1 }
        }
        return true
    }

    public mutating func clear() {
        items.removeAll()
        currentIndex = -1
        shuffleHistory.removeAll()
    }

    public mutating func move(fromOffsets: IndexSet, toOffset: Int) {
        // 重排前按稳定 ID 记住当前条目，重排后恢复其索引
        var currentID: UUID?
        if currentIndex >= 0, currentIndex < items.count {
            currentID = items[currentIndex].id
        }
        items.move(fromOffsets: fromOffsets, toOffset: toOffset)
        if let currentID, let newIdx = items.firstIndex(where: { $0.id == currentID }) {
            currentIndex = newIdx
        }
    }

    public mutating func jumpTo(itemID: UUID) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return false }
        if mode == .shuffle, let current = currentItem {
            shuffleHistory.append(current.id)
        }
        currentIndex = idx
        return true
    }

    // MARK: - 导航

    public mutating func next() -> QueueItem? {
        guard !items.isEmpty else { return nil }
        if mode == .shuffle, let current = currentItem {
            shuffleHistory.append(current.id)
        }

        switch mode {
        case .loopOne:
            return currentItem
        case .sequential:
            guard currentIndex < items.count - 1 else { return nil }
            currentIndex += 1
            return currentItem
        case .loopAll:
            currentIndex = (currentIndex + 1) % items.count
            return currentItem
        case .shuffle:
            let remaining = items.indices.filter { $0 != currentIndex && !shuffleHistory.contains(items[$0].id) }
            if let nextIdx = remaining.randomElement() {
                currentIndex = nextIdx
            } else {
                // 全部听过，清空历史重新随机
                shuffleHistory.removeAll()
                let candidates = items.indices.filter { $0 != currentIndex }
                if let nextIdx = candidates.randomElement() { currentIndex = nextIdx }
            }
            return currentItem
        }
    }

    public mutating func previous() -> QueueItem? {
        guard !items.isEmpty else { return nil }

        switch mode {
        case .loopOne:
            return currentItem
        case .shuffle:
            if let lastID = shuffleHistory.popLast(),
               let idx = items.firstIndex(where: { $0.id == lastID }) {
                currentIndex = idx
                return currentItem
            }
            return currentItem
        default:
            guard currentIndex > 0 else { return nil }
            currentIndex -= 1
            return currentItem
        }
    }

    public mutating func handleEnded() -> QueueItem? {
        guard !items.isEmpty else { return nil }
        switch mode {
        case .loopOne: return currentItem
        case .sequential:
            guard currentIndex < items.count - 1 else { return nil }
            currentIndex += 1
            return currentItem
        case .loopAll:
            currentIndex = (currentIndex + 1) % items.count
            return currentItem
        case .shuffle:
            return next()
        }
    }
}
