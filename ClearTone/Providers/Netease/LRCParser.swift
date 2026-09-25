import Foundation

/// 解析 LRC / YRC 歌词，支持翻译、音译、逐字时间、重复时间戳与异常行
public enum LRCParser {

    // MARK: - 普通 LRC
    public static func parse(_ lrc: String, translation: String? = nil, romanization: String? = nil) -> [LyricLine] {
        let mainLines = parseLRC(lrc)
        let transLines = translation.map { parseLRC($0) } ?? []
        let romaLines = romanization.map { parseLRC($0) } ?? []

        // 合并翻译与音译（按时间对齐）
        var merged: [TimeInterval: LyricLine] = [:]
        for line in mainLines {
            merged[line.time] = line
        }
        for line in transLines {
            if var existing = merged[line.time] {
                existing.translation = line.text
                merged[line.time] = existing
            }
        }
        for line in romaLines {
            if var existing = merged[line.time] {
                existing.romanization = line.text
                merged[line.time] = existing
            }
        }

        return merged.sorted { $0.key < $1.key }.map(\.value)
    }

    // MARK: - 逐字 YRC
    public static func parseYRC(_ yrc: String, translation: String? = nil, romanization: String? = nil) -> [LyricLine] {
        // YRC 格式: [start,duration]word(start,duration,0)word...
        // 示例: [12340,500]我(12340,200,0)们(12540,300,0)...
        let pattern = #"\[(\d+),(\d+)\]([^\[]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var lines: [LyricLine] = []
        let nsString = yrc as NSString
        let matches = regex.matches(in: yrc, range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }
            let startMs = Double(nsString.substring(with: match.range(at: 1))) ?? 0
            let durationMs = Double(nsString.substring(with: match.range(at: 2))) ?? 0
            let content = nsString.substring(with: match.range(at: 3))

            let time = startMs / 1000.0
            let words = parseYRCWords(content, baseTime: time)

            let line = LyricLine(time: time, text: words.map(\.text).joined(), words: words)
            lines.append(line)
        }

        // 合并翻译
        if let trans = translation, !trans.isEmpty {
            let transLines = parseLRC(trans)
            var transMap: [TimeInterval: String] = [:]
            for t in transLines { transMap[t.time] = t.text }
            for i in lines.indices {
                if let transText = transMap[lines[i].time] {
                    lines[i].translation = transText
                }
            }
        }

        return lines.sorted { $0.time < $1.time }
    }

    private static func parseYRCWords(_ content: String, baseTime: TimeInterval) -> [LyricWord] {
        // 格式: word(start,duration,0)
        let pattern = #"([^(]+)\((\d+),(\d+),\d+\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var words: [LyricWord] = []
        let nsString = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }
            let text = nsString.substring(with: match.range(at: 1))
            let startMs = Double(nsString.substring(with: match.range(at: 2))) ?? 0
            let durationMs = Double(nsString.substring(with: match.range(at: 3))) ?? 0
            words.append(LyricWord(time: startMs / 1000.0, duration: durationMs / 1000.0, text: text))
        }

        return words
    }

    // MARK: - 基础 LRC 解析
    private static func parseLRC(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let pattern = #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for rawLine in lrc.components(separatedBy: .newlines) {
            let nsString = rawLine as NSString
            let matches = regex.matches(in: rawLine, range: NSRange(location: 0, length: nsString.length))
            guard !matches.isEmpty else { continue }

            // 提取歌词文本（最后一个 ] 之后的内容）
            var textEnd = 0
            for match in matches {
                textEnd = max(textEnd, match.range.upperBound)
            }
            let text = nsString.substring(from: textEnd).trimmingCharacters(in: .whitespaces)

            for match in matches {
                guard match.numberOfRanges >= 3 else { continue }
                let minutes = Double(nsString.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(nsString.substring(with: match.range(at: 2))) ?? 0
                var fraction: Double = 0
                if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound {
                    let fracStr = nsString.substring(with: match.range(at: 3))
                    fraction = (Double(fracStr) ?? 0) / pow(10.0, Double(fracStr.count))
                }
                let time = minutes * 60 + seconds + fraction
                lines.append(LyricLine(time: time, text: text))
            }
        }

        return lines.sorted { $0.time < $1.time }
    }

    // MARK: - 二分查找当前歌词行
    public static func currentLineIndex(in lines: [LyricLine], at time: TimeInterval, offset: TimeInterval = 0) -> Int? {
        guard !lines.isEmpty else { return nil }
        let adjustedTime = time + offset
        var low = 0
        var high = lines.count - 1
        var result: Int?

        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= adjustedTime {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}
