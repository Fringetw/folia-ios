import Foundation

// Account-scoped playlist snapshots contain metadata and local IDs, never expiring audio URLs.
struct YouTubePlaylistChoice: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    var isLocal: Bool { id.hasPrefix("local-") }
    var collection: LibraryCollection { id == "liked" ? .liked : .playlist(id) }
    static let liked = YouTubePlaylistChoice(id: "liked", title: "喜歡的影片")
}

struct SyncedYouTubeSong: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let videoID: String
    let title: String
    let artist: String
    var duration: Double?
    var channelID: String? = nil
    var avatarURL: URL? = nil
    var localTrackID: String? = nil
    init(local track: Track) {
        id = "file-" + UUID().uuidString; videoID = id; title = track.title
        artist = track.artist ?? ""; duration = track.duration; localTrackID = track.id
    }
    init?(_ entry: LibraryEntry) {
        guard let videoID = YouTubeVideo.identifier(from: entry.url.absoluteString) else { return nil }
        id = entry.id; self.videoID = videoID; title = entry.title; artist = entry.subtitle; duration = entry.duration; channelID = entry.channelID
    }
}

struct YouTubeAudioBinding: Codable, Equatable, Sendable {
    let trackID: String
    let quality: String
}

struct FoliaPlaylistEdits: Codable, Equatable {
    var name: String?
    var added: [SyncedYouTubeSong] = []
    var removed: Set<String> = []
    var order: [String] = []
    func applying(to source: [SyncedYouTubeSong]) -> [SyncedYouTubeSong] {
        var seen = Set<String>()
        let rows = (source + added).filter { !removed.contains($0.id) && seen.insert($0.id).inserted }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var ordered = Set<String>()
        return order.compactMap { id in ordered.insert(id).inserted ? byID[id] : nil }
            + rows.filter { !ordered.contains($0.id) }
    }
}

struct FoliaSavedPlaylist: Codable, Equatable {
    let choice: YouTubePlaylistChoice
    let songs: [SyncedYouTubeSong]
    let lastSync: Date?
}

struct YouTubeSyncSnapshot: Codable, Equatable {
    var choice: YouTubePlaylistChoice?
    var songs: [SyncedYouTubeSong] = []
    var bindings: [String: YouTubeAudioBinding] = [:]
    var lastSync: Date?
    var attempts: [String: Date]? = nil
    var edits: [String: FoliaPlaylistEdits]? = nil
    var saved: [String: FoliaSavedPlaylist]? = nil
    var currentEdits: FoliaPlaylistEdits { choice.flatMap { edits?[$0.id] } ?? FoliaPlaylistEdits() }
    var playlistTitle: String { currentEdits.name ?? choice?.title ?? "Folia 播放清單" }
    var playlistSongs: [SyncedYouTubeSong] { currentEdits.applying(to: songs) }
}

struct DownloadAudioCandidate: Sendable {
    let url: URL
    let title: String
    let artist: String
    let duration: Double
    let format: String
    let bitrate: Int
    let source: String
    var localTrackID: String? = nil
    var recording: SubtitleSong? = nil
    var streamingURL: URL? = nil
    var expectedBytes: Int? = nil
    var sampleRate: Double? = nil
    var bits: Int? = nil
    var lossless: Bool { ["flac", "alac", "wav", "aiff", "aif"].contains(format.lowercased()) }
    var quality: String { source + " · " + format.uppercased() + (lossless ? " 無損" : source == "本機音檔" ? "" : bitrate > 0 ? " \(bitrate / 1000) kbps" : " 原始音質") }
    static func preferred(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.lossless != rhs.lossless { return lhs.lossless }
        if lhs.lossless {
            if lhs.bits != rhs.bits { return (lhs.bits ?? 0) > (rhs.bits ?? 0) }
            if lhs.sampleRate != rhs.sampleRate { return (lhs.sampleRate ?? 0) > (rhs.sampleRate ?? 0) }
        }
        return lhs.bitrate > rhs.bitrate
    }
}

enum DownloadSongMatch {
    static func downloadOrder(_ songs: [SyncedYouTubeSong], attempts: [String: Date]) -> [SyncedYouTubeSong] {
        var seen = Set<String>()
        return songs.enumerated().filter { seen.insert($0.element.videoID).inserted }.sorted {
            let a = attempts[$0.element.videoID] ?? .distantPast, b = attempts[$1.element.videoID] ?? .distantPast
            return a == b ? $0.offset < $1.offset : a < b
        }.map { $0.element }
    }
    static func searchTitle(_ title: String) -> String {
        let brackets = #"(?i)[【\[(（]([^】\])）]*)[】\])）]"#
        var clean = title
        if let regex = try? NSRegularExpression(pattern: brackets) {
            for match in regex.matches(in: title, range: NSRange(title.startIndex..., in: title)).reversed() {
                guard let all = Range(match.range, in: clean), let inside = Range(match.range(at: 1), in: clean) else { continue }
                let label = String(clean[inside])
                if versions(label).isEmpty && (label.range(of: #"(?i)中文字幕|中[日英韓]?字幕|繁[中體]|中字|歌詞翻譯|歌词翻译|official|music video|^\s*mv\s*$|4k"#, options: .regularExpression) != nil) {
                    clean.replaceSubrange(all, with: " ")
                }
            }
        }
        clean = clean.replacingOccurrences(of: #"(?i)\s+(?:official(?: music)? (?:video|audio)|lyrics? (?:music )?video|music video|official mv|mv|lyrics|中字|中文字幕)\s*$"#,
            with: "", options: .regularExpression)
        return clean.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let traditional = folded.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false) ?? folded
        return traditional.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func versions(_ title: String) -> Set<Int> {
        let rules = [#"\blive\b|現場|现场|ライブ|ライヴ"#, #"\bremix\b|混音|リミックス"#,
            #"\bcover\b|翻唱"#, #"\bacoustic\b|不插[電电]|アコースティック"#,
            #"\b(?:instrumental|karaoke|off[ -]?vocal)\b|伴奏|カラオケ"#,
            #"\b(?:sped[ -]?up|nightcore|slowed)\b|加速|降速"#,
            #"\b(?:tv[ -](?:size|ver(?:sion)?)|short ver(?:sion)?|radio edit|medley|extended mix|re-recorded|piano ver(?:sion)?)\b|短版|串[燒烧]|オルゴール"#]
        return Set(rules.indices.filter { title.range(of: rules[$0], options: [.regularExpression, .caseInsensitive]) != nil })
    }
    static func sameDuration(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b, a.isFinite, b.isFinite, a > 0, b > 0 else { return false }
        return abs(a - b) <= min(8, max(2, min(a, b) * 0.02))
    }
    static func artistNames(_ text: String) -> [String] {
        let clean = text.replacingOccurrences(of: #"(?i)\s*[-–—]\s*Topic\s*$"#, with: "", options: .regularExpression)
        return clean.components(separatedBy: CharacterSet(charactersIn: "/／、,，&＆;；×"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    // QQ uses the Chinese credit for this artist on releases also listed under the Japanese name.
    private static let utadaKeys = Set(["宇多田光", "宇多田ヒカル", "Hikaru Utada"].map(normalized))

    static func artistKeys(_ text: String) -> Set<String> {
        var keys = Set<String>()
        for name in artistNames(text) {
            let bare = name.replacingOccurrences(of: #"[（(][\p{Hiragana}\p{Katakana}ー\s]+[）)]$"#, with: "", options: .regularExpression)
            let full = normalized(bare)
            if !full.isEmpty { keys.insert(full) }
            if bare.range(of: #"\p{Latin}"#, options: .regularExpression) != nil,
               bare.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil {
                for pattern in [#"[^\p{Han}\p{Hiragana}\p{Katakana}ー・]"#, #"[^\p{Latin}]"#] {
                    let alias = normalized(bare.replacingOccurrences(of: pattern, with: "", options: .regularExpression))
                    if alias.count >= 2 { keys.insert(alias) }
                }
            }
        }
        if !keys.isDisjoint(with: utadaKeys) { keys.formUnion(utadaKeys) }
        return keys
    }
    static func matches(_ song: SyncedYouTubeSong, title: String, artists: [String], duration: Double?) -> Bool {
        let versionTags = versions(song.title)
        guard let expected = song.duration, let duration, expected.isFinite, duration.isFinite,
              expected > 0, duration > 0, duration <= 5400, versionTags == versions(title) else { return false }
        let metadata = YouTubeCaptionDecoders.metadata(id: song.videoID, title: song.title, artist: song.artist, duration: expected)
        let performers = artistNames(metadata.artist)
        let videoPresentation = song.title.range(of: #"(?i)music video|official mv|\bmv\b|【AMV|「[^」]+」"#, options: .regularExpression) != nil
        // A duet video can have an intro even if the uploader omits "MV" from "Artists - Song".
        // Only allow a shorter album candidate with the same exact title and all credited artists.
        let hasMultipleCredits = versionTags.isEmpty && performers.count > 1
            && song.title.components(separatedBy: " - ").count == 2
            && normalized(metadata.title) == normalized(searchTitle(title))
        let difference = expected - duration
        let labelledVideoLength = videoPresentation && difference >= -3 && difference <= 18
        let creditedVideoLength = hasMultipleCredits && difference > 0 && difference <= min(18, expected * 0.06)
        guard sameDuration(expected, duration) || labelledVideoLength || creditedVideoLength else { return false }
        let keys = artists.reduce(into: Set<String>()) { $0.formUnion(artistKeys($1)) }
        let requested = artistKeys(metadata.artist).union(artistKeys(song.artist))
        guard !keys.isDisjoint(with: requested) else { return false }
        if performers.count > 1 {
            guard performers.allSatisfy({ !keys.isDisjoint(with: artistKeys($0)) }) else { return false }
        }
        let candidate = titleKeys(title)
        guard !candidate.isEmpty else { return false }
        var forms = titleKeys(metadata.title).union(titleKeys(song.title))
        for name in artists {
            forms.formUnion(titleKeys(searchTitle(song.title).replacingOccurrences(of: name, with: "", options: .caseInsensitive)))
        }
        return !candidate.isDisjoint(with: forms)
    }

    private static func titleKeys(_ title: String) -> Set<String> {
        let cleaned = searchTitle(title)
        var variants = [cleaned]
        if versions(title).isEmpty {
            variants += cleaned.components(separatedBy: CharacterSet(charactersIn: "/／|｜「」『』\"“”"))
            for variant in variants {
                if let match = variant.firstMatch(of: #/^(.+?)\s*[(（]([^()（）]+)[)）]\s*$/#) {
                    let first = String(match.1), alias = String(match.2)
                    let cjk = { (value: String) in value.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#, options: .regularExpression) != nil }
                    let kana = { (value: String) in value.range(of: #"[\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil }
                    // E.g. QQ's Japanese song title followed by its Chinese translation.
                    if cjk(first) != cjk(alias) || (cjk(first) && kana(first) != kana(alias)) {
                        variants.append(first); variants.append(alias)
                    }
                }
            }
        }
        return Set(variants.map(normalized).filter { !$0.isEmpty })
    }

    static func safeAudioURL(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value), parts.scheme == "https", let host = parts.host,
              !host.isEmpty, parts.user == nil, parts.password == nil, parts.fragment == nil else { return nil }
        return parts.url
    }
}

enum AudioRetryPolicy {
    static func delay(status: Int, retryAfter: String?) -> Double? {
        guard status == 429 || status == 503 else { return nil }
        let value = Double(retryAfter ?? "") ?? 60
        return value.isFinite ? min(3600, max(1, value)) : 60
    }
}
