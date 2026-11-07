import Foundation

struct YouTubeCaptionTrack: Sendable, Equatable {
    let url: URL
    let language: String
    let automatic: Bool
    let original: Bool
    var chinese: Bool { language.lowercased() == "zh" || language.lowercased().hasPrefix("zh-") }
}

struct YouTubeWebCaptionRequest: Sendable {
    let videoID: String
    let version: String
    let script: URL
    let endpoint: URL
    let headers: [String: String]

    func body(signatureTimestamp: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "WEB", "clientVersion": version]],
            "videoId": videoID,
            "playbackContext": ["contentPlaybackContext": [
                "html5Preference": "HTML5_PREF_WANTS", "signatureTimestamp": signatureTimestamp
            ]]
        ])
    }
}

// Public page data only; do not evaluate page scripts or manufacture machine-translated tracks.
enum YouTubeCaptionDecoders {
    static func embeddedObject(_ page: String, name: String) throws -> [String: Any] {
        try embeddedObject(page, markers: [name + " =", name + "=", "[\"" + name + "\"] =", "[\"" + name + "\"]="])
    }
    private static func embeddedObject(_ page: String, markers: [String],
                                       matching: ([String: Any]) -> Bool = { _ in true }) throws -> [String: Any] {
        guard page.utf8.count <= 8_000_000 else { throw SubtitleReadError("invalid-response") }
        for marker in markers {
            var offset = page.startIndex
            for _ in 0..<16 {
                guard let found = page.range(of: marker, range: offset..<page.endIndex) else { break }
                offset = found.upperBound
                let tail = page[offset...].drop(while: \.isWhitespace)
                guard tail.first == "{" else { continue }
                if let object = jsonObject(in: page, at: tail.startIndex), matching(object) { return object }
            }
        }
        if page.contains("consent.youtube.com") || page.contains("/sorry/") || page.contains("unusual traffic") {
            throw SubtitleReadError("verification-required")
        }
        throw SubtitleReadError("invalid-response")
    }

    private static func jsonObject(in page: String, at start: String.Index) -> [String: Any]? {
        var quoted = false, escaped = false, depth = 0, cursor = start
        while cursor < page.endIndex {
            let char = page[cursor]
            if quoted {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { quoted = false }
            } else if char == "\"" { quoted = true }
            else if char == "{" { depth += 1; if depth > 128 { return nil } }
            else if char == "}" {
                depth -= 1
                if depth == 0 { return try? SubtitleSourceDecoders.object(Data(page[start...cursor].utf8)) }
            }
            cursor = page.index(after: cursor)
        }
        return nil
    }
    private static func text(_ raw: Any?) -> String {
        if let raw = raw as? String { return raw }
        guard let value = raw as? [String: Any] else { return "" }
        return (value["simpleText"] as? String) ?? (value["runs"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }.joined()
    }
    static func searchURL(_ query: String, requireCaptions: Bool = true) -> URL {
        var url = URLComponents(string: "https://www.youtube.com/results")!
        // Observed from YouTube's visible Subtitles/CC filter. URLComponents encodes the percent signs once more.
        url.queryItems = [.init(name: "search_query", value: query + (requireCaptions ? " 中文字幕" : " 中文 歌詞")),
            .init(name: "hl", value: "zh-TW"), .init(name: "gl", value: "TW")]
        if requireCaptions { url.queryItems?.append(.init(name: "sp", value: "EgIoAQ%3D%3D")) }
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.url!
    }
    static func search(_ page: String) throws -> [SubtitleRecord] {
        let root = try embeddedObject(page, name: "ytInitialData")
        var songs: [SubtitleRecord] = [], seen = Set<String>(), visits = 0
        func visit(_ node: Any, depth: Int) {
            guard depth < 64, visits < 50_000, songs.count < 8 else { return }
            visits += 1
            if let dict = node as? [String: Any] {
                if let video = dict["videoRenderer"] as? [String: Any], let id = video["videoId"] as? String,
                   YouTubeVideo.validID(id), seen.insert(id).inserted {
                    let title = text(video["title"]), artist = text(video["ownerText"] ?? video["longBylineText"])
                    let parts = text(video["lengthText"]).split(separator: ":").compactMap { Double($0) }
                    let seconds = parts.reduce(0) { $0 * 60 + $1 }
                    if !title.isEmpty, !artist.isEmpty, seconds > 0, seconds <= 3600 {
                        let translated = isTranslatedUpload(title)
                        songs.append(SubtitleRecord(song: metadata(id: id, title: title, artist: artist, duration: seconds),
                            translatedVideo: translated, translatedCCHint: translated && hasCCHint(title), uploader: artist))
                    }
                    return
                }
                // Dictionary order is not stable; preserve the site's result order via its content arrays.
                for key in dict.keys.sorted() { if let value = dict[key] { visit(value, depth: depth + 1) } }
            } else if let list = node as? [Any] { for value in list { visit(value, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        guard !songs.isEmpty || root["estimatedResults"] as? String == "0" else { throw SubtitleReadError("invalid-response") }
        return songs
    }
    static func isTranslatedUpload(_ title: String) -> Bool {
        title.range(of: #"中[日英韓]?(?:雙語)?字幕|繁[中體]|中字|中文[翻譯歌詞]+|中文[翻译歌词]+|中日歌詞|繁中/日歌詞|Chinese subtitles"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func hasCCHint(_ title: String) -> Bool {
        title.range(of: #"CC\s*字幕|(?:中文|繁中|繁體)\s*CC"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func rankedSearchResults(withCC: [SubtitleRecord], broad: [SubtitleRecord]) -> [SubtitleRecord] {
        // The CC filter can surface translated uploads absent from the broad search.
        // It proves that an upload has a track, while its watch page determines the language.
        let translatedWithCC = withCC.filter(\.translatedVideo)
        let ordered = translatedWithCC.filter(\.translatedCCHint) + translatedWithCC + broad.filter(\.translatedVideo) + withCC + broad
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.song.id).inserted }
    }

    private static func parallelArtistCredit(_ text: String) -> String? {
        guard let latin = text.range(of: #"\p{Latin}"#, options: .regularExpression) else { return nil }
        let nativeNames = DownloadSongMatch.artistNames(String(text[..<latin.lowerBound]))
        let latinNames = DownloadSongMatch.artistNames(String(text[latin.lowerBound...]))
        guard nativeNames.count >= 2, nativeNames.count == latinNames.count,
              nativeNames.allSatisfy({ $0.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#, options: .regularExpression) != nil }),
              latinNames.allSatisfy({ $0.range(of: #"^[\p{Latin} .'-]+$"#, options: .regularExpression) != nil }) else { return nil }
        return nativeNames.joined(separator: " / ")
    }

    private static func creditedArtists(_ text: String) -> String {
        if let parallel = parallelArtistCredit(text) { return parallel }
        return DownloadSongMatch.artistNames(text).map { part in
            let east = part.replacingOccurrences(of: #"[^\p{Han}\p{Hiragana}\p{Katakana}ー・]"#, with: "", options: .regularExpression)
            return east.count >= 2 && part.range(of: #"\p{Latin}"#, options: .regularExpression) != nil ? east : part
        }.joined(separator: " / ")
    }

    static func metadata(id: String, title: String, artist: String, duration: Double) -> SubtitleSong {
        // Only presentation labels are removed. Live/cover/remix/version markers must remain.
        let labels = #"\s*[【\[(（]\s*(?:中[日英韓]?字幕|中[日英韓]雙語字幕|中文字幕|中字|中文翻譯|中文翻译|CC字幕|official(?: music)? (?:video|audio)|lyrics?(?: video)?)\s*[】\])）]\s*"#
        let clean = title.replacingOccurrences(of: labels, with: " ", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes = clean.matches(of: #/[「『]([^」』]+)[」』]/#)
        let themeTitle = quotes.first { quote in
            // Soundtrack uploads often quote the film or anime title before the song.
            let prefix = clean[..<quote.range.lowerBound].suffix(36)
            return prefix.range(of: #"(?:片頭曲|片尾曲|插曲|主題曲|主题曲|テーマ曲|(?<![A-Za-z])(?:OP|ED)[0-9]*)\s*[:：]?\s*$"#,
                                options: [.regularExpression, .caseInsensitive]) != nil
        }
        if DownloadSongMatch.versions(title).isEmpty, let quoted = themeTitle ?? quotes.first {
            let extracted = String(quoted.1).trimmingCharacters(in: .whitespacesAndNewlines)
            let tailCredit = clean[quoted.range.upperBound...].split(maxSplits: 1, omittingEmptySubsequences: false) {
                $0 == "|" || $0 == "｜"
            }.first ?? ""
            let tail = DownloadSongMatch.searchTitle(String(tailCredit))
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:："))
            let head = DownloadSongMatch.searchTitle(String(clean[..<quoted.range.lowerBound]))
            let headKey = DownloadSongMatch.normalized(head)
            let uploaderKeys = DownloadSongMatch.artistKeys(artist)
            let credit = !tail.isEmpty && tail.count <= 150 && tail.range(of: #"(?i)^[\p{L}\p{N} &＆、,，/／×・.]+$"#, options: .regularExpression) != nil
                ? tail : uploaderKeys.contains(where: { $0.count >= 2 && headKey.contains($0) }) ? head : artist
            if !extracted.isEmpty {
                return SubtitleSong(id: id, source: "ytm", title: extracted, artist: creditedArtists(credit), durationMs: duration * 1000)
            }
        }
        let titleParts = clean.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // An explicit Artist - Song credit is more useful than a translation channel's name.
        let prefixArtist = titleParts.count == 2 && !titleParts[0].isEmpty ? titleParts[0] : artist
        let uploader = artist.replacingOccurrences(of: #"\s*-\s*Topic\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let key = { (text: String) in text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber } }
        // Official titles often add a Latin alias, e.g. 米津玄師 Kenshi Yonezu - Lemon.
        // Keep the attested channel name when it is part of that artist credit.
        func scriptAlias(_ text: String) -> String? {
            let pattern = #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}ー・]{2,40}"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard matches.count == 1, let range = Range(matches[0].range, in: text) else { return nil }
            return String(text[range])
        }
        let latin = { (text: String) in key(text.replacingOccurrences(of: #"[^\p{Latin}]"#, with: "", options: .regularExpression)) }
        let sharedAlias = scriptAlias(prefixArtist)
        let aliasesAgree = sharedAlias != nil && sharedAlias == scriptAlias(uploader)
            && latin(prefixArtist).count >= 3 && latin(prefixArtist) == latin(uploader)
        let creditedArtist = aliasesAgree ? sharedAlias!
            : key(uploader).count >= 3 && key(prefixArtist).contains(key(uploader)) ? uploader : prefixArtist
        let creditedTitle = titleParts.count == 2 && !titleParts[1].isEmpty ? titleParts[1] : clean
        return SubtitleSong(id: id, source: "ytm", title: creditedTitle,
            artist: parallelArtistCredit(creditedArtist) ?? creditedArtist, durationMs: duration * 1000)
    }
    static func playerResponse(_ page: String, videoID: String) throws -> [String: Any] {
        let root = try embeddedObject(page, name: "ytInitialPlayerResponse")
        try validatePlayer(root, videoID: videoID)
        return root
    }
    private static func validatePlayer(_ root: [String: Any], videoID: String) throws {
        if let status = root["playabilityStatus"] as? [String: Any], let value = status["status"] as? String, value != "OK" {
            let reason = (status["reason"] as? String ?? "").lowercased()
            let challenge = reason.contains("bot") || reason.contains("verify") || reason.contains("驗證")
            throw SubtitleReadError(value == "LOGIN_REQUIRED" && !challenge ? "not-signed-in" : "verification-required")
        }
        guard let details = root["videoDetails"] as? [String: Any], details["videoId"] as? String == videoID else {
            throw SubtitleReadError("invalid-response")
        }
    }

    static func webCaptionRequest(_ page: String, videoID: String) throws -> YouTubeWebCaptionRequest {
        let watch = try playerResponse(page, videoID: videoID)
        guard YouTubeVideo.validID(videoID), (watch["playabilityStatus"] as? [String: Any])?["status"] as? String == "OK" else {
            throw SubtitleReadError("verification-required")
        }
        let config = try embeddedObject(page, markers: ["ytcfg.set("]) {
            $0["INNERTUBE_CONTEXT"] is [String: Any] && $0["INNERTUBE_API_KEY"] is String
        }
        let context = config["INNERTUBE_CONTEXT"] as? [String: Any]
        let client = context?["client"] as? [String: Any]
        let scriptPath = (config["PLAYER_JS_URL"] as? String)
            ?? page.firstMatch(of: #/"(?:jsUrl|PLAYER_JS_URL)"\s*:\s*"([^"]+\/base\.js)"/#).map { String($0.1) }
        let origin = "https://www.youtube.com"
        guard client?["clientName"] as? String == "WEB",
              let version = (config["INNERTUBE_CLIENT_VERSION"] as? String) ?? (client?["clientVersion"] as? String),
              version.range(of: #"^[0-9.]{3,32}$"#, options: .regularExpression) != nil,
              let key = config["INNERTUBE_API_KEY"] as? String,
              key.range(of: #"^[A-Za-z0-9_-]{20,128}$"#, options: .regularExpression) != nil,
              let scriptPath, scriptPath.count <= 512,
              let script = URL(string: scriptPath, relativeTo: URL(string: origin))?.absoluteURL,
              script.scheme == "https", script.host == "www.youtube.com", script.user == nil, script.password == nil,
              script.port == nil, script.query == nil, script.fragment == nil,
              script.path.hasPrefix("/s/player/"), script.path.hasSuffix("/base.js") else { throw SubtitleReadError("invalid-response") }
        var endpoint = URLComponents(string: origin + "/youtubei/v1/player")!
        endpoint.queryItems = [.init(name: "prettyPrint", value: "false"), .init(name: "key", value: key)]
        var headers = ["Origin": origin, "Accept-Language": "en-US,en", "X-Youtube-Client-Name": "1", "X-Youtube-Client-Version": version]
        for (field, name) in [("VISITOR_DATA", "X-Goog-Visitor-Id"), ("USER_AGENT", "User-Agent")] {
            if let value = config[field] as? String, !value.isEmpty, value.utf8.count <= 1024,
               value.rangeOfCharacter(from: .controlCharacters) == nil { headers[name] = value }
        }
        if headers["User-Agent"] == nil { headers["User-Agent"] = "Mozilla/5.0" }
        return YouTubeWebCaptionRequest(videoID: videoID, version: version, script: script, endpoint: endpoint.url!, headers: headers)
    }

    static func signatureTimestamp(_ data: Data) throws -> Int {
        guard let text = String(data: data, encoding: .utf8),
              let match = text.firstMatch(of: #/(?:signatureTimestamp|sts)\s*:\s*([0-9]{5})/#),
              let stamp = Int(match.1) else { throw SubtitleReadError("invalid-response") }
        return stamp
    }

    static func tracks(_ page: String, videoID: String) throws -> [YouTubeCaptionTrack] {
        try tracks(player: playerResponse(page, videoID: videoID), videoID: videoID)
    }

    static func tracks(playerData: Data, videoID: String) throws -> [YouTubeCaptionTrack] {
        let root = try SubtitleSourceDecoders.object(playerData)
        try validatePlayer(root, videoID: videoID)
        guard (root["playabilityStatus"] as? [String: Any])?["status"] as? String == "OK" else {
            throw SubtitleReadError("invalid-response")
        }
        return tracks(player: root, videoID: videoID)
    }

    private static func tracks(player root: [String: Any], videoID: String) -> [YouTubeCaptionTrack] {
        let captions = root["captions"] as? [String: Any]
        let renderer = captions?["playerCaptionsTracklistRenderer"] as? [String: Any]
        let listed = renderer?["captionTracks"] as? [[String: Any]] ?? []
        let audio = renderer?["audioTracks"] as? [[String: Any]] ?? []
        let audioIndex = renderer?["defaultAudioTrackIndex"] as? Int ?? 0
        let defaultIndex = audio.indices.contains(audioIndex) ? audio[audioIndex]["defaultCaptionTrackIndex"] as? Int : nil
        return listed.prefix(60).enumerated().compactMap { index, track in
            guard let language = track["languageCode"] as? String, let raw = track["baseUrl"] as? String,
                  language.range(of: #"^[A-Za-z0-9-]{2,32}$"#, options: .regularExpression) != nil,
                  var parts = URLComponents(string: raw), allowedCaptionURL(parts.url),
                  let queryItems = parts.queryItems, queryItems.filter({ $0.name == "v" }).map(\.value) == [videoID],
                  !queryItems.contains(where: { $0.name == "tlang" }) else { return nil }
            // Keep the platform's signed parameters byte-for-byte; only the output format changes.
            let query = (parts.percentEncodedQuery ?? "").split(separator: "&").filter { !$0.hasPrefix("fmt=") }
            parts.percentEncodedQuery = (query.map(String.init) + ["fmt=json3"]).joined(separator: "&")
            guard let url = parts.url else { return nil }
            return YouTubeCaptionTrack(url: url, language: language, automatic: track["kind"] as? String == "asr", original: index == defaultIndex)
        }
    }
    static func allowedCaptionURL(_ url: URL?) -> Bool {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil, parts.port == nil,
              ["www.youtube.com", "youtube.com"].contains(parts.host?.lowercased() ?? ""), parts.path == "/api/timedtext" else { return false }
        return true
    }
    static func cues(_ data: Data, chinese: Bool = false) throws -> [LyricLine] {
        let root = try SubtitleSourceDecoders.object(data)
        guard let events = root["events"] as? [[String: Any]], events.count <= 20_000 else { throw SubtitleReadError("invalid-response") }
        let lines = events.compactMap { event -> LyricLine? in
            guard let segments = event["segs"] as? [[String: Any]], segments.count <= 2000,
                  event["tStartMs"] != nil, event["dDurationMs"] != nil else { return nil }
            guard let startValue = event["tStartMs"] as? NSNumber, let lengthValue = event["dDurationMs"] as? NSNumber,
                  startValue.doubleValue.isFinite, startValue.doubleValue >= 0, lengthValue.doubleValue.isFinite else { return nil }
            let start = startValue.doubleValue / 1000
            let duration = SubtitleSourceDecoders.number(event["dDurationMs"]) / 1000
            let text = segments.compactMap { $0["utf8"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard start <= 3600, duration > 0, duration <= 120, !text.isEmpty, text.utf8.count <= 64_000,
                  !text.contains("\u{0000}") else { return nil }
            if chinese, let pair = bilingualCue(text) {
                return LyricLine(startTime: start, endTime: start + duration, fullText: pair.original, translation: pair.chinese)
            }
            return LyricLine(startTime: start, endTime: start + duration, fullText: text)
        }
        return LyricTimeline(lines: lines).lines
    }
    static func bilingualCue(_ text: String) -> (original: String, chinese: String)? {
        let rows = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (2...6).contains(rows.count) else { return nil }
        var originals: [String] = [], translations: [String] = []
        for row in rows {
            let kanaOrHangul = row.range(of: #"[\p{Hiragana}\p{Katakana}\p{Hangul}]"#, options: .regularExpression) != nil
            let han = row.unicodeScalars.filter { $0.properties.isIdeographic }.count
            let letters = row.unicodeScalars.filter { $0.properties.isAlphabetic }.count
            if !kanaOrHangul, han >= 2, han * 2 >= letters { translations.append(row) }
            else if kanaOrHangul || (han == 0 && row.range(of: "[A-Za-z]", options: .regularExpression) != nil) { originals.append(row) }
            else { return nil } // Two all-Han rows or ambiguous text cannot prove which one is the original.
        }
        guard !originals.isEmpty, !translations.isEmpty else { return nil }
        return (originals.joined(separator: "\n"), translations.joined(separator: "\n"))
    }
    static func bilingual(chinese: [LyricLine], original: [LyricLine]?, sameVideoBaseline: [LyricLine] = []) -> [LyricLine] {
        // Only the very same video may use its existing lyric clock without a second original track.
        // Other videos must supply their own original text for the plugin to prove a cross-video match.
        let original = original?.isEmpty == false ? original! : sameVideoBaseline
        guard !original.isEmpty else { return chinese }
        let translatedText = chinese.map { line in
            LyricLine(startTime: line.startTime, endTime: line.endTime, fullText: line.translation ?? line.fullText)
        }
        let paired = SubtitleSourceDecoders.attach(original, translations: translatedText)
        return paired.contains(where: { $0.translation != nil }) ? paired : chinese
    }
}
