import Foundation

/// **保序** JSON 编码。
///
/// eapi 专用的保序 JSON 编码。
///
/// iOS 的 eapi / xeapi 生产路径通过 `NeteaseDirectTransport` 使用它，并被
/// `NeteaseEapiTests` 完整覆盖 —— 保留它才不会在重新启用时需要重写一遍。
///
/// ## 为什么不能直接用 `JSONSerialization`
///
/// 网易云的 eapi 接口把请求参数的 `JSON.stringify` 结果拼进签名串
/// （`nobody<uri>use<text>md5forencrypt`），服务端会用同样规则重算并比对。
/// 也就是说 **JSON 的字节序列本身参与鉴权**。
///
/// 而 `JSONSerialization` 的 `.sortedKeys` 会重排键，无选项时又依赖
/// `Dictionary` 的哈希遍历顺序 —— 两者都与 Node 的
/// `JSON.stringify`（保持插入顺序）不一致。同样的键值、不同的键序
/// 会算出完全不同的 MD5，服务端一律拒绝。
///
/// 所以凡是走 eapi 的请求，参数必须用这个类型按插入顺序显式构造。
public enum OrderedJSON {

    public indirect enum Value: Sendable {
        case string(String)
        case int(Int)
        case bool(Bool)
        case double(Double)
        case array([Value])
        case object([(String, Value)])
        case null

        /// 从任意 `[String: String]` 构造，**键按字典序排列**。
        ///
        /// 仅用于键序与 Node 侧字面量一致的场合；顺序敏感的场景请手工列 pairs。
        public static func orderedObject(_ dict: [String: String]) -> Value {
            .object(dict.keys.sorted().map { ($0, .string(dict[$0]!)) })
        }

        public static func strings(_ values: [String]) -> Value {
            .array(values.map { .string($0) })
        }

        /// 取出 object 的原始 pairs（非 object 返回空）。
        /// eapi 需要在既有键之后按固定顺序追加 `e_r` / `header`。
        public var objectPairs: [(String, Value)] {
            if case .object(let pairs) = self { return pairs }
            return []
        }

        /// 追加键值对。仅对 `.object` 有效，其余返回 self。
        public func appending(_ pairs: [(String, Value)]) -> Value {
            if case .object(let existing) = self { return .object(existing + pairs) }
            return self
        }
    }

    /// 编码为紧凑 JSON（无空白），与 `JSON.stringify` 的默认输出等价。
    public static func encode(_ value: Value) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    private static func write(_ value: Value, into out: inout String) {
        switch value {
        case .string(let s):
            out += quote(s)
        case .int(let i):
            out += String(i)
        case .bool(let b):
            out += b ? "true" : "false"
        case .double(let d):
            // JS 的 Number→String：整数不带小数点
            if d == d.rounded(), abs(d) < 1e15 {
                out += String(Int64(d))
            } else {
                out += String(d)
            }
        case .null:
            out += "null"
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { out += "," }
                out += quote(pair.0)
                out += ":"
                write(pair.1, into: &out)
            }
            out += "}"
        }
    }

    /// 与 `JSON.stringify` 一致的字符串转义。
    ///
    /// 关键控制字符用短形式（`\n` `\t` …），其余走 `\uXXXX`；
    /// 斜杠、正斜杠不转义（与 JS 一致）。
    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
