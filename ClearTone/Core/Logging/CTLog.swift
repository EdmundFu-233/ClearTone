import Foundation
import os.log

/// 统一日志，自动脱敏敏感字段（cookie、token、key）
public enum CTLog {
    private static let subsystem = "com.cleartone.app"

    public static let general = Logger(subsystem: subsystem, category: "general")
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let playback = Logger(subsystem: subsystem, category: "playback")
    public static let helper = Logger(subsystem: subsystem, category: "helper")
    public static let render = Logger(subsystem: subsystem, category: "render")
    public static let security = Logger(subsystem: subsystem, category: "security")

    /// 脱敏处理：隐藏 cookie、token、key、MUSIC_U 等敏感值
    public static func sanitize(_ message: String) -> String {
        var result = message
        let patterns = [
            #"(MUSIC_U|__csrf|NMTID|cookie|token|key)=([^;\s&]+)"#,
            #"(password|pwd)=([^&\s]+)"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "$1=***"
                )
            }
        }
        return result
    }

    public static func redact(_ value: String?) -> String {
        guard let value = value, !value.isEmpty else { return "<empty>" }
        if value.count <= 8 { return "***" }
        return "\(value.prefix(4))...\(value.suffix(4))"
    }
}
