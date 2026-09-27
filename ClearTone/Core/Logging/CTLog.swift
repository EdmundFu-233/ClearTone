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

    /// 敏感字段名。集中成一处：加一个字段只改这一行。
    ///
    /// `MUSIC_A`（账号 id）、`MUSIC_R`、`__remember_me` 是此前漏掉的 ——
    /// 网易云 `MUSIC_U` 之外的凭据同样不该进日志。
    nonisolated private static let secretKeys = [
        "MUSIC_U", "MUSIC_A", "MUSIC_R", "MUSIC_H", "__csrf", "__remember_me",
        "NMTID", "cookie", "set-cookie", "token", "access_token", "refresh_token",
        "key", "password", "pwd", "auth", "authorization", "secret", "session",
    ].joined(separator: "|")

    /// 脱敏处理：隐藏 cookie、token、key、MUSIC_U 等敏感值。
    ///
    /// 三种形态都要覆盖，漏一个就等于没脱敏：
    /// - `"MUSIC_U":"xxx"` —— JSON 形态。Cookie 注入请求体后就是这个形状，
    ///   原实现只认 `KEY=VALUE`，于是整串凭据原样进了日志。
    /// - `MUSIC_U=xxx&...` —— query 形态。
    /// - `Authorization: Bearer <jwt>` —— header 形态，**值里含空格**，
    ///   所以要单独一条规则，否则只会抹掉 `Bearer` 而把 JWT 留在日志里。
    ///
    /// 每条规则的第一个捕获组都是**要原样保留的部分**，替换模板只抹掉值。
    /// 过度脱敏比漏脱敏安全，所以宁可多吃一点上下文。
    nonisolated public static func sanitize(_ message: String) -> String {
        var result = message
        let rules: [(pattern: String, template: String)] = [
            ("\\b((?:authorization|auth)\\s*[=:]\\s*)[^\\n;,\"'}]+", "$1***"),
            ("\"((?:\(secretKeys)))\"\\s*:\\s*(?:\"[^\"]*\"|[^,}\\s]+)", "\"$1\":\"***\""),
            // `\b` 保证不会误伤 cacheKey / monkey 这类只是碰巧含 key 的词
            ("\\b((?:\(secretKeys))\\s*[=:]\\s*)[^;,\\s&}\"']+", "$1***"),
        ]
        for rule in rules {
            guard let regex = try? NSRegularExpression(
                pattern: rule.pattern, options: .caseInsensitive
            ) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template
            )
        }
        return result
    }

    nonisolated public static func redact(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "<empty>" }
        if value.count <= 8 { return "***" }
        return "\(value.prefix(4))...\(value.suffix(4))"
    }
}
