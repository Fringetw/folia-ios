import Foundation

// Anonymous, read-only subtitle sources. No platform cookies or Google credentials are sent here.
actor SubtitleNetwork {
    static let shared = SubtitleNetwork()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 7
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()
    private var blockedUntil: [String: Date] = [:]

    static func neteaseURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        return parts.url
    }

    static func neteaseForm(_ query: String) -> Data {
        var form = URLComponents()
        form.queryItems = [.init(name: "s", value: query), .init(name: "type", value: "1"),
            .init(name: "limit", value: "8"), .init(name: "offset", value: "0")]
        // In an HTML form '+' means a space; preserve a literal plus in song names.
        return Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }

    func search(_ query: String, provider: String, netease: String, current: SubtitleSong?) async throws -> [SubtitleRecord] {
        switch provider {
        case "netease":
            let data: Data
            if let custom = Self.neteaseURL(netease) {
                data = try await read(url: url(base: custom, path: "search", query: [
                    .init(name: "keywords", value: query), .init(name: "type", value: "1"),
                    .init(name: "limit", value: "8"), .init(name: "offset", value: "0")]), provider: provider)
            } else {
                // The desktop service uses the cloud-search form endpoint. The older GET web route
                // can return HTTP 200 without a result object in some native client environments.
                data = try await read(url: URL(string: "https://music.163.com/api/cloudsearch/pc")!, provider: provider,
                    body: Self.neteaseForm(query), contentType: "application/x-www-form-urlencoded")
            }
            return try decoding(data, stage: "search", SubtitleSourceDecoders.neteaseSearch)
        case "qq":
            let data = try await read(url: url(base: URL(string: "https://c.y.qq.com")!, path: "soso/fcgi-bin/client_search_cp",
                query: [.init(name: "w", value: String(query.prefix(60))), .init(name: "format", value: "json"),
                        .init(name: "p", value: "1"), .init(name: "n", value: "8")]), provider: provider)
            return try SubtitleSourceDecoders.qqSearch(data)
        case "ytm":
            let found = try await rankedYouTubeSearch(query)
            var seen = Set<String>()
            let translated = found.filter(\.translatedVideo)
            let playing: [SubtitleRecord] = current.flatMap { song in
                let id = song.originVideoID ?? (song.source == "ytm" ? song.id : "")
                guard YouTubeVideo.validID(id) else { return nil }
                return [SubtitleRecord(song: SubtitleSong(id: id, source: "ytm", title: song.title,
                    artist: song.artist, durationMs: song.durationMs))]
            } ?? []
            return Array((translated + playing + found).filter { seen.insert($0.song.id).inserted }.prefix(8))
        case "lrclib":
            let data = try await read(url: url(base: URL(string: "https://lrclib.net/api")!, path: "search",
                query: [.init(name: "q", value: query)]), provider: provider)
            let records = try JSONDecoder().decode([LyricSearchRecord].self, from: data)
            return records.prefix(8).map { record in
                SubtitleRecord(song: SubtitleSong(id: String(record.id), source: provider, title: record.trackName,
                    artist: record.artistName, durationMs: record.duration * 1000),
                    lines: record.syncedLyrics.map { LyricTimeline(lrc: $0).lines })
            }
        default: throw SubtitleReadError("unsupported")
        }
    }

    private func youtubeSearch(_ query: String, requireCaptions: Bool) async throws -> [SubtitleRecord] {
        let data = try await read(url: YouTubeCaptionDecoders.searchURL(query, requireCaptions: requireCaptions), provider: "ytm")
        guard let page = String(data: data, encoding: .utf8) else { throw SubtitleReadError("invalid-response") }
        return try YouTubeCaptionDecoders.search(page)
    }

    private func rankedYouTubeSearch(_ query: String) async throws -> [SubtitleRecord] {
        async let cc = youtubeSearch(query, requireCaptions: true)
        async let broad = youtubeSearch(query, requireCaptions: false)
        let withCC: [SubtitleRecord]
        do {
            withCC = try await cc
        } catch {
            try Task.checkCancellation()
            return YouTubeCaptionDecoders.rankedSearchResults(withCC: [], broad: try await broad)
        }
        let general = (try? await broad) ?? []
        try Task.checkCancellation()
        return YouTubeCaptionDecoders.rankedSearchResults(withCC: withCC, broad: general)
    }

    func translationVideos(title: String, artist: String) async throws -> [SubtitleRecord] {
        let performers = DownloadSongMatch.artistNames(artist).joined(separator: " ")
        let query = String((title + " " + performers).prefix(110))
        return Array(try await rankedYouTubeSearch(query).filter(\.translatedVideo).prefix(8))
    }

    func lyrics(_ record: SubtitleRecord, netease: String, original: [LyricLine], current: SubtitleSong? = nil) async throws -> [LyricLine] {
        let song = record.song
        let lines: [LyricLine]
        switch song.source {
        case "netease":
            guard !song.id.isEmpty, song.id.allSatisfy(\.isNumber) else { throw SubtitleReadError("invalid-response") }
            let custom = Self.neteaseURL(netease)
            let data = try await read(url: url(base: custom ?? URL(string: "https://music.163.com")!,
                path: custom == nil ? "api/song/lyric" : "lyric", query: [.init(name: "id", value: song.id),
                    .init(name: "lv", value: "-1"), .init(name: "tv", value: "-1"), .init(name: "rv", value: "-1")]), provider: song.source)
            lines = try decoding(data, stage: "lyrics", SubtitleSourceDecoders.neteaseLyrics)
        case "qq":
            guard let id = Int64(song.id), id > 0 else { throw SubtitleReadError("invalid-response") }
            let b64 = { (value: String) in Data(value.utf8).base64EncodedString() }
            let payload: [String: Any] = [
                "comm": ["ct": 11, "cv": "1003006", "v": "1003006", "tmeAppID": "qqmusiclight", "uid": "0"],
                "request": ["module": "music.musichallSong.PlayLyricInfo", "method": "GetPlayLyricInfo", "param": [
                    "songID": id, "songName": b64(song.title), "singerName": b64(song.artist), "albumName": "",
                    "interval": Int(song.durationMs / 1000), "crypt": 0, "ct": 19, "cv": 2111,
                    "lrc_t": 0, "qrc": 0, "qrc_t": 0, "roma": 1, "roma_t": 0, "trans": 1, "trans_t": 0, "type": 0]]]
            let data = try await read(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!, provider: "qq",
                body: JSONSerialization.data(withJSONObject: payload))
            lines = try SubtitleSourceDecoders.qqLyrics(data)
        case "ytm":
            let sameVideo = current?.source == "ytm" && current?.id == song.id
            lines = try await youtubeLyrics(id: song.id, baseline: original, sameVideo: sameVideo)
        case "lrclib": lines = record.lines ?? []
        default: throw SubtitleReadError("unsupported")
        }
        let prepared = LyricTimeline(lines: lines).prepared(for: song.durationMs / 1000).lines
        guard !prepared.isEmpty else { throw SubtitleReadError("empty") }
        return prepared
    }

    func youtubeLyrics(id: String, baseline: [LyricLine] = [], sameVideo: Bool = false) async throws -> [LyricLine] {
        guard YouTubeVideo.validID(id) else { throw SubtitleReadError("invalid-response") }
        let data = try await read(url: url(base: URL(string: "https://www.youtube.com")!, path: "watch",
            query: [.init(name: "v", value: id), .init(name: "hl", value: "zh-TW")]), provider: "ytm")
        guard let page = String(data: data, encoding: .utf8) else { throw SubtitleReadError("invalid-response") }
        let tracks = try YouTubeCaptionDecoders.tracks(page, videoID: id)
        do {
            return try await chineseCaptions(tracks, baseline: baseline, sameVideo: sameVideo)
        } catch let initial as SubtitleReadError where initial.code == "caption-read-failed" {
            do {
                let request = try YouTubeCaptionDecoders.webCaptionRequest(page, videoID: id)
                let script = try await read(url: request.script, provider: "ytm")
                let stamp = try YouTubeCaptionDecoders.signatureTimestamp(script)
                let fresh = try await read(url: request.endpoint, provider: "ytm", body: request.body(signatureTimestamp: stamp), headers: request.headers)
                let refreshed = try YouTubeCaptionDecoders.tracks(playerData: fresh, videoID: id)
                return try await chineseCaptions(refreshed, baseline: baseline, sameVideo: sameVideo, userAgent: request.headers["User-Agent"])
            } catch is CancellationError { throw CancellationError() }
            catch {
                let refreshed = (error as? SubtitleReadError) ?? SubtitleReadError("network")
                let details = [initial.detail, "重新取得字幕軌：\(refreshed.detail ?? refreshed.explanation)"].compactMap { $0 }
                throw SubtitleReadError(initial.code, detail: details.joined(separator: "；"))
            }
        }
    }

    private func chineseCaptions(_ tracks: [YouTubeCaptionTrack], baseline: [LyricLine], sameVideo: Bool, userAgent: String? = nil) async throws -> [LyricLine] {
        // Only existing manually supplied Chinese tracks, without generating translations.
        let chinese = tracks.filter { $0.chinese && !$0.automatic }.sorted {
            let preferred = ["zh-Hant", "zh-TW", "zh-HK", "zh", "zh-Hans", "zh-CN"]
            return (preferred.firstIndex(of: $0.language) ?? 99) < (preferred.firstIndex(of: $1.language) ?? 99)
        }
        guard !chinese.isEmpty else { throw SubtitleReadError("captions-unavailable") }
        let sample = baseline.prefix(80).map(\.fullText).joined().prefix(8000)
        let hint = sample.range(of: #"[\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil ? "ja"
            : sample.range(of: #"\p{Hangul}"#, options: .regularExpression) != nil ? "ko"
            : sample.range(of: "[A-Za-z]", options: .regularExpression) != nil ? "en" : nil
        let originals = tracks.filter { !$0.chinese && !$0.automatic }
        let original = originals.first { $0.original }
            ?? hint.flatMap { code in originals.first { $0.language == code } }
            ?? (originals.count == 1 ? originals.first : nil)
        async let originalCues: [LyricLine]? = optionalCaption(original, userAgent: userAgent)
        var failures: [SubtitleReadError] = []
        for track in chinese.prefix(3) {
            do {
                let lines = try await caption(track, userAgent: userAgent)
                guard !lines.isEmpty else { throw SubtitleReadError("caption-read-failed", detail: "沒有有效時間軸") }
                return YouTubeCaptionDecoders.bilingual(chinese: lines, original: await originalCues,
                    sameVideoBaseline: sameVideo ? baseline : [])
            } catch is CancellationError { throw CancellationError() }
            catch {
                let failure = (error as? SubtitleReadError) ?? SubtitleReadError("network")
                failures.append(SubtitleReadError(failure.code, detail: "\(track.language)：\(failure.detail ?? failure.explanation)"))
            }
        }
        let detail = failures.compactMap(\.detail).joined(separator: "；")
        let code = failures.contains { $0.code == "caption-read-failed" } ? "caption-read-failed" : failures.first?.code ?? "caption-read-failed"
        throw SubtitleReadError(code, detail: detail)
    }
    private func caption(_ track: YouTubeCaptionTrack, userAgent: String?) async throws -> [LyricLine] {
        guard let id = URLComponents(url: track.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
              YouTubeVideo.validID(id) else { throw SubtitleReadError("invalid-response") }
        var headers = ["Referer": "https://www.youtube.com/watch?v=" + id]
        headers["User-Agent"] = userAgent
        let data = try await read(url: track.url, provider: "ytm", headers: headers)
        guard !data.isEmpty else { throw SubtitleReadError("caption-read-failed", detail: "YouTube 回傳空白字幕") }
        return try YouTubeCaptionDecoders.cues(data, chinese: track.chinese)
    }
    private func optionalCaption(_ track: YouTubeCaptionTrack?, userAgent: String?) async -> [LyricLine]? {
        guard let track else { return nil }
        return try? await caption(track, userAgent: userAgent)
    }
    private func decoding<T>(_ data: Data, stage: String, _ decode: (Data) throws -> T) throws -> T {
        do { return try decode(data) }
        catch {
            let code = (error as? SubtitleReadError)?.code ?? "invalid-response"
            throw SubtitleReadError(code, detail: "\(stage): \(SubtitleSourceDecoders.replySummary(data))")
        }
    }
    private func url(base: URL, path: String, query: [URLQueryItem]) -> URL {
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }
    private func read(url: URL, provider: String, body: Data? = nil, contentType: String = "application/json",
                      headers: [String: String] = [:]) async throws -> Data {
        try Task.checkCancellation()
        guard Date() >= (blockedUntil[provider] ?? .distantPast) else { throw SubtitleReadError("rate-limited") }
        var request = URLRequest(url: url, timeoutInterval: 7)
        request.setValue(provider == "ytm" ? "Mozilla/5.0 Folia-iOS/0.3.3" : "Folia-iOS/0.3.3", forHTTPHeaderField: "User-Agent")
        if provider == "netease" { request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer") }
        if provider == "qq" {
            request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            request.setValue("okhttp/3.14.9", forHTTPHeaderField: "User-Agent")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let policy = SubtitleRedirectGuard(host: url.host ?? "", port: url.port)
        let (bytes, response) = try await session.bytes(for: request, delegate: policy)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw SubtitleReadError("network") }
        if http.statusCode == 429 || http.statusCode == 503 {
            let delay = min(3600, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60))
            blockedUntil[provider] = Date().addingTimeInterval(delay)
            throw SubtitleReadError("rate-limited")
        }
        if http.statusCode == 401 { throw SubtitleReadError("not-signed-in") }
        if http.statusCode == 403 || http.statusCode == 451 { throw SubtitleReadError("region-restricted") }
        guard (200..<300).contains(http.statusCode), response.expectedContentLength <= 8_000_000 else { throw SubtitleReadError("unavailable") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 8_000_000 else { throw SubtitleReadError("invalid-response") }
            data.append(byte)
        }
        return data
    }
}

private final class SubtitleRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let host: String
    let port: Int?
    init(host: String, port: Int?) { self.host = host; self.port = port }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == host, parts.port == port,
              parts.user == nil, parts.password == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}
