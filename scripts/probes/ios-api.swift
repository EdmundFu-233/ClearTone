import Foundation

/// 无 Cookie 的直连探针，不读本机钥匙串、不执行写操作、不输出登录 key 或播放 URL。
@main
struct IOSAPIProbe {
    static func main() async {
        var failed = 0
        let transport = NeteaseDirectTransport.shared
        func probe(_ route: String, _ query: [String: String] = [:]) async -> [String: Any]? {
            do {
                let data = try await transport.mobileRequest(route, query: query, cookie: nil)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicError.invalidResponse }
                let code = json["code"] as? Int ?? 0
                guard [200, 801, 802].contains(code) else { throw MusicError.apiError(code: code, message: "接口响应异常") }
                print("PASS \(route) code=\(code) bytes=\(data.count)")
                return json
            } catch {
                failed += 1
                print("FAIL \(route) \(error.ctUserMessage)")
                return nil
            }
        }
        if !CommandLine.arguments.contains("--playback-only") {
        for type in ["1", "100", "10", "1000"] {
            _ = await probe("/cloudsearch", ["keywords": "周杰伦", "type": type, "limit": "5", "offset": "0"])
        }
        _ = await probe("/song/detail", ["ids": "347230"])
        _ = await probe("/lyric/new", ["id": "347230"])
        _ = await probe("/album", ["id": "18918"])
        _ = await probe("/artist/detail", ["id": "6452"])
        _ = await probe("/artist/top/song", ["id": "6452"])
        _ = await probe("/artist/album", ["id": "6452", "limit": "5"])
        _ = await probe("/comment/new", ["id": "347230", "type": "0", "sortType": "99", "pageNo": "1", "pageSize": "5"])
        if let recommendations = await probe("/personalized", ["limit": "3"]),
           let playlist = (recommendations["result"] as? [[String: Any]])?.first,
           let id = playlist["id"] {
            _ = await probe("/playlist/detail", ["id": String(describing: id)])
            _ = await probe("/playlist/track/all", ["id": String(describing: id), "limit": "5", "offset": "0"])
        }
        if let login = await probe("/login/qr/key"), let key = (login["data"] as? [String: Any])?["unikey"] as? String {
            _ = await probe("/login/qr/check", ["key": key])
        }
        }
        var playable = false
        for query in ["生日歌", "纯音乐", "Canon", "Kevin MacLeod"] {
            guard let found = await probe("/cloudsearch", ["keywords": query, "type": "1", "limit": "30"]),
                  let songs = (found["result"] as? [String: Any])?["songs"] as? [[String: Any]] else {
                print("FAIL song search result schema"); failed += 1; continue
            }
            let candidates = songs.filter { ($0["fee"] as? Int) == 0 }.prefix(5)
            print("Search samples: \(songs.count), free samples: \(candidates.count)")
            for song in candidates {
                guard let id = song["id"] else { continue }
                if let playback = await probe("/song/url/v1", ["id": String(describing: id), "level": "standard"]),
                   let item = (playback["data"] as? [[String: Any]])?.first {
                    let hasURL = (item["url"] as? String)?.isEmpty == false
                    print("Playback URL present: \(hasURL), item code=\(item["code"] ?? "unknown")")
                    if hasURL, let raw = item["url"] as? String,
                       let url = URL(string: raw.replacingOccurrences(of: "http://", with: "https://", options: .anchored)) {
                        let config = URLSessionConfiguration.ephemeral
                        config.timeoutIntervalForRequest = 15
                        config.httpCookieStorage = nil
                        let session = URLSession(configuration: config)
                        defer { session.invalidateAndCancel() }
                        var request = URLRequest(url: url)
                        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
                        do {
                            let (bytes, response) = try await session.bytes(for: request)
                            guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else { throw MusicError.noPlayableURL }
                            var count = 0
                            for try await _ in bytes { count += 1; if count >= 1024 { break } }
                            if count > 0 {
                                print("PASS audio CDN HTTP=\(http.statusCode) sampled=\(count) bytes")
                                playable = true; break
                            }
                        } catch { print("Audio sample unavailable: \(error.ctUserMessage)") }
                    }
                }
            }
            if playable { break }
        }
        if !playable { print("FAIL no playable public sample"); failed += 1 }
        print("Failures: \(failed)")
        if failed > 0 { exit(1) }
    }
}
