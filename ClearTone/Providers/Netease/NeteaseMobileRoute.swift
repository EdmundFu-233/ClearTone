import Foundation

/// iOS 原生传输要复现 Node module 的参数改名、固定值与复合路由。
/// 不把 helper query 原样发送给上游（例如 cloudsearch 的 keywords 实际叫 s）。
enum NeteaseMobileRoute {
    struct Request: Sendable {
        let path: String
        let crypto: NeteaseEndpoint.Crypto
        let payload: OrderedJSON.Value
    }

    static func qrURL(key: String) throws -> URL {
        var parts = URLComponents(string: "https://music.163.com/login")!
        parts.queryItems = [URLQueryItem(name: "codekey", value: key)]
        guard let url = parts.url else { throw MusicError.invalidResponse }
        return url
    }

    static func make(_ route: String, query: [String: String]) throws -> Request {
        guard let endpoint = NeteaseEndpoint.endpoint(forRoute: route) else {
            throw MusicError.unknown("接口未适配：\(route)")
        }
        var path = endpoint.apiPath
        // 加密方式一律取登记表，本地不再覆写 —— 覆写过的地方正是表被写错
        // 却没人发现的原因（`/login/qr/key`、`/logout` 曾被标成 `.plain`）。
        let crypto = endpoint.crypto
        var pairs: [(String, OrderedJSON.Value)] = []
        func string(_ key: String, _ value: String?) { if let value { pairs.append((key, .string(value))) } }
        func number(_ key: String, _ value: Int) { pairs.append((key, .int(value))) }
        switch route {
        case "/search/suggest":
            // search_suggest.js: data 只有 `{ s: query.keywords }`，
            // 路径按 type 分流（`mobile` → keyword，其余 → web）；
            // 本应用不传 type，所以固定打 web，与登记表一致。
            string("s", query["keywords"])
        case "/song/detail":
            let ids = try songIDs(query["ids"] ?? "")
            string("c", OrderedJSON.encode(.array(ids.map { .object([("id", .int($0))]) })))
        case "/song/url/v1":
            let ids = try songIDs(query["id"] ?? "")
            string("ids", OrderedJSON.encode(.array(ids.map { .int($0) })))
            string("level", query["level"] ?? "standard"); string("encodeType", "flac")
        case "/song/url/match":
            // 这是 Node 的第三方解锁复合逻辑，设备直连不会冒充已完成解锁。
            throw MusicError.unknown("此歌曲没有可用的网易云播放地址")
        case "/playlist/detail", "/playlist/track/all":
            string("id", query["id"]); number("n", 100000)
            if let s = query["s"] { string("s", s) } else { number("s", 8) }
        case "/lyric/new":
            string("id", query["id"]); pairs.append(("cp", .bool(false)))
            for key in ["tv", "lv", "rv", "kv", "yv", "ytv", "yrv"] { number(key, 0) }
        case "/album":
            guard let id = query["id"], Int64(id) != nil else { throw MusicError.invalidResponse }
            path = path.replacingOccurrences(of: "{id}", with: id)
        case "/artist/album":
            guard let id = query["id"], Int64(id) != nil else { throw MusicError.invalidResponse }
            path = path.replacingOccurrences(of: "{id}", with: id)
            string("limit", query["limit"] ?? "30"); string("offset", query["offset"] ?? "0")
            pairs.append(("total", .bool(true)))
        case "/user/playlist":
            string("uid", query["uid"]); string("limit", query["limit"] ?? "30")
            string("offset", query["offset"] ?? "0"); pairs.append(("includeVideo", .bool(true)))
        case "/personalized":
            string("limit", query["limit"] ?? "30"); pairs.append(("total", .bool(true))); number("n", 1000)
        case "/playlist/create":
            string("name", query["name"]); string("privacy", query["privacy"] ?? "0")
            string("type", query["type"] ?? "NORMAL")
        case "/playlist/delete":
            let ids = try songIDs(query["id"] ?? "")
            string("ids", OrderedJSON.encode(.array(ids.map { .int($0) })))
        case "/playlist/tracks":
            string("op", query["op"]); string("pid", query["pid"])
            string("trackIds", OrderedJSON.encode(.strings((query["tracks"] ?? "").split(separator: ",").map(String.init))))
            string("imme", "true")
        case "/song/like":
            string("trackId", query["id"]); string("userid", query["uid"])
            pairs.append(("like", .bool(query["like"] != "false")))
        case "/comment/like":
            path = query["t"] == "1" ? "/api/v1/comment/like" : "/api/v1/comment/unlike"
            string("threadId", "R_SO_4_" + (query["id"] ?? "")); string("commentId", query["cid"])
        case "/cloudsearch":
            // 上游是 `query.type || 1` 这一套默认值。调用方每次都传齐，
            // 补默认值只是为了让 payload 形状与辅助进程逐字一致 ——
            // 少一个键就是另一个签名。
            var normalized = query
            normalized["type"] = query["type"] ?? "1"
            normalized["limit"] = query["limit"] ?? "30"
            normalized["offset"] = query["offset"] ?? "0"
            guard let payload = NeteaseEndpoint.orderedPayload(forRoute: route, query: normalized) else { throw MusicError.invalidResponse }
            return Request(path: path, crypto: crypto, payload: payload)
        // 走登记表的键序：uri、加密方式、payload 三者都由 NeteaseEndpoint 一处说了算，
        // 这里只负责把 helper 的 query 交给它。早先这几条在本地另拼一份 payload，
        // 于是登记表写错了也没人发现（`/login/qr/key` 的 uri 与 crypto 都曾是错的）。
        case "/artist/detail", "/artist/songs", "/likelist", "/comment/new", "/playlist/name/update",
             "/login/qr/key", "/login/qr/check", "/logout", "/search/hot", "/toplist":
            guard let payload = NeteaseEndpoint.orderedPayload(forRoute: route, query: query) else { throw MusicError.invalidResponse }
            return Request(path: path, crypto: crypto, payload: payload)
        case "/user/account", "/recommend/resource", "/recommend/songs", "/artist/top/song":
            pairs = query.filter { !["timestamp", "randomCNIP"].contains($0.key) }.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }
        default:
            // 可测试的逐路由适配；没有适配的路由显式报错，不猜测参数。
            throw MusicError.unknown("iOS 暂未适配此接口：\(route)")
        }
        return Request(path: path, crypto: crypto, payload: .object(pairs))
    }

    static func songIDs(_ raw: String) throws -> [Int] {
        let items = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !items.isEmpty, items.count <= 1000 else { throw MusicError.invalidResponse }
        return try items.map {
            guard let value = Int($0), value > 0 else { throw MusicError.invalidResponse }
            return value
        }
    }
}
