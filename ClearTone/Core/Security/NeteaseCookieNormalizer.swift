import Foundation

/// 网易云 cookie 的归一化。
///
/// ## 为什么要归一化
///
/// 扫码登录时 `api/module/login_qr_check.js` 返回的是
/// `cookie: result.cookie.join(';')` —— `result.cookie` 是**一整组
/// `Set-Cookie` 响应头**，而每个元素本身就长这样：
///
/// ```
/// MUSIC_U=xxx; Max-Age=15552000; Expires=Sun, 28 Mar 2027 21:05:37 GMT; Path=/
/// ```
///
/// 再用 `;` 一拼，得到的字符串有 **134 段**、6 个真实 cookie 之外还混着
/// `Expires` / `Max-Age` / `Path`，以及空值的 `MUSIC_SNS=`、重复出现的
/// `MUSIC_R_U`。原实现把这个字符串**原样存进钥匙串**，于是每一个请求的
/// `Cookie:` 头都带着 140 个 pair，其中 `Expires=Mon, 18 Oct 2094 00:19:44 GMT`
/// 这种**值里带空格、逗号、冒号且未编码**的内容。
///
/// ## 为什么不是「顺手清理一下」而是必须修
///
/// 归一化后 cookie 从 134 段降到 6 段，请求显著变小，且不再把
/// `Expires=...GMT` 这种非法 cookie 值发给上游。上游对
/// 「Cookie 头畸形 + 写操作」的风控判定未知，但这至少不是一个
/// 我们自己制造出来的、把写接口往风控方向推的因素。
///
/// ## 保留策略
///
/// - 只保留 `name=value`，丢掉 `Expires` / `Max-Age` / `Path` / `Domain`
///   / `Secure` / `HttpOnly` / `SameSite` / `Priority` 这些**属性**；
/// - 同名取**第一次**出现（`Set-Cookie` 里后写的会覆盖先写的，但
///   这里取先出现的更接近「服务端主动下发」的顺序，且稳定）；
/// - 丢弃空值（`MUSIC_SNS=` 是服务端正在删它，留在请求里只会误导）。
public enum NeteaseCookieNormalizer {

    /// cookie 属性名，不是 cookie 名。这些不该被当成凭据发出去。
    private static let attributeNames: Set<String> = [
        "expires", "max-age", "path", "domain", "secure",
        "httponly", "samesite", "priority", "comment", "version",
    ]

    /// 把扫码登录拿到的原始 cookie 串归一化成 `k=v; k=v` 形式。
    ///
    /// 已经是规范形式的输入会被原样重建（只做去重与丢弃空值），
    /// 所以这个函数是**幂等**的，可以放心在每次读取凭据时调用。
    public static func normalize(_ raw: String) -> String {
        var seen = Set<String>()
        var pairs: [String] = []

        for segment in raw.split(separator: ";", omittingEmptySubsequences: true) {
            let item = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { continue }
            // 只要第一个 `=`：值里可能有 `=`（少见但合法）
            guard let separator = item.firstIndex(of: "=") else { continue }
            let name = String(item[item.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
            let value = String(item[item.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)

            guard !name.isEmpty, !value.isEmpty else { continue }
            let lowerName = name.lowercased()
            guard !attributeNames.contains(lowerName) else { continue }
            guard seen.insert(name).inserted else { continue }
            pairs.append("\(name)=\(value)")
        }

        return pairs.joined(separator: "; ")
    }

    /// 归一化是否值得做（已规范时返回原串，避免无谓的字符串重建）。
    public static func normalized(_ raw: String) -> String {
        let result = normalize(raw)
        return result == raw.trimmingCharacters(in: .whitespacesAndNewlines) ? raw : result
    }
}
