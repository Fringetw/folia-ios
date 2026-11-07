import CryptoKit
import Foundation
import UniformTypeIdentifiers
import Observation
import WebKit
import SwiftUI

@MainActor @Observable
final class SubtitleController: NSObject, WKNavigationDelegate {
    var preferences: SubtitlePreferences { didSet {
        if oldValue.sourceKey != preferences.sourceKey {
            cancelRequests(); accountKey = UUID().uuidString; sourceStatus.removeAll(); sourceDiagnostics.removeAll()
        }
        save()
        var previous = oldValue; previous.reportVisible = preferences.reportVisible
        if previous != preferences { configureEngine() }
        updateReport()
    } }
    private(set) var timeline = LyricTimeline(lines: [])
    private(set) var revision = UUID()
    private(set) var reportText = "目前沒有歌曲。"
    private(set) var reportJSON = Data("{}".utf8)
    private(set) var sourceStatus: [String: String] = [:]
    private(set) var engineError: String?
    var notice: String?
    var currentSearchTerms: (String, String)? { input.map { (matchingSong($0.song).title, matchingSong($0.song).artist) } }
    private(set) var videoProgress: String?
    private(set) var translationPreview: TranslationPreview?
    @ObservationIgnored private var videoTask: Task<Void, Never>?
    @ObservationIgnored private var videoRevision = UUID()
    @ObservationIgnored private var manual: SavedTranslation?
    struct TranslationPreview {
        let lines: [LyricLine]
        let source: String
        let aligned: Bool
    }
    private struct SavedTranslation: Codable {
        let source: String
        let duration: Double
        let title: String
        let lines: [LyricLine]
    }
    private var base: LyricTimeline { manual.map { LyricTimeline(lines: $0.lines) } ?? raw }
    @ObservationIgnored private var webView: WKWebView?
    private(set) var ready = false
    @ObservationIgnored private var configurationRevision = 0
    @ObservationIgnored private var hostLease: UUID?
    @ObservationIgnored private var recoveries = 0
    @ObservationIgnored private var recoveryWindow = Date.distantPast
    @ObservationIgnored private var probing = false
    @ObservationIgnored private var engineGeneration = UUID()
    @ObservationIgnored private var input: SubtitleInput?
    @ObservationIgnored private var raw = LyricTimeline(lines: [])
    @ObservationIgnored private var token = UUID().uuidString
    @ObservationIgnored private var accountKey = UUID().uuidString
    @ObservationIgnored private var library: LocalLibrary?
    @ObservationIgnored private var account: NavidromeAccount?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var candidates: [String: Candidate] = [:]
    @ObservationIgnored private var candidateOrder: [String] = []
    @ObservationIgnored private var fixture = false
    @ObservationIgnored private var sourceDiagnostics: [String: String] = [:]
    @ObservationIgnored private var engineReportText = "目前沒有歌曲。"
    @ObservationIgnored private var engineReport: [String: Any] = [:]
    private enum Candidate { case local(Track), navidrome(Track), record(SubtitleRecord) }

    override init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--subtitle-reset") {
            UserDefaults.standard.removeObject(forKey: "Folia.BuiltInTraditionalLyrics.v1")
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: "Folia.BuiltInTraditionalLyrics.v1"),
           let saved = try? JSONDecoder().decode(SubtitlePreferences.self, from: data) { preferences = saved }
        else { preferences = SubtitlePreferences() }
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(SubtitleMessageHandler(self), name: "subtitles")
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.backgroundColor = .clear
        view.isUserInteractionEnabled = false; view.accessibilityElementsHidden = true
        view.navigationDelegate = self
        view.isInspectable = false
        webView = view
        if let file = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "FoliaSubtitles") {
            view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        } else { engineError = "內建字幕引擎遺失，請更新安裝版本。" }
        #if DEBUG
        fixture = ProcessInfo.processInfo.arguments.contains("--subtitle-fixture")
        #endif
    }

    func sources(library: LocalLibrary, account: NavidromeAccount?) {
        self.library = library
        if self.account != account {
            cancelRequests(); self.account = account; accountKey = UUID().uuidString
            sourceStatus.removeAll(); sourceDiagnostics.removeAll(); engineReport = [:]
        }
        configureEngine()
    }

    func load(_ next: SubtitleInput?, timeline rawTimeline: LyricTimeline) {
        guard input != next else { return }
        let sameSong = input?.song.id == next?.song.id && input?.song.source == next?.song.source
        let previousRaw = raw.lines
        cancelRequests()
        if !sameSong {
            cancelTranslationRead(); translationPreview = nil; manual = nil
            sourceStatus.removeAll(); sourceDiagnostics.removeAll()
        }
        input = next; token = UUID().uuidString
        if !sameSong || !rawTimeline.lines.isEmpty || next?.loading != true {
            raw = rawTimeline.prepared(for: (next?.song.durationMs ?? 0) / 1000)
        }
        #if DEBUG
        if fixture, next?.song.source == "demo" {
            raw = LyricTimeline(lines: [LyricLine(startTime: 0, endTime: 30, fullText: "头发发现", translation: "风里的回声",
                words: [LyricWord(text: "头发", startTime: 0, endTime: 15), LyricWord(text: "发现", startTime: 15, endTime: 30)])])
        }
        #endif
        if let song = next?.song, song.durationMs > 0, next?.loading == false {
            if let manual, !matches(manual, song) { self.manual = nil }
            if manual == nil, let file = translationFile(song),
               let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
               let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(SavedTranslation.self, from: data),
               matches(stored, song) { manual = stored }
        }
        if !sameSong || previousRaw != raw.lines || manual != nil { apply(preferences.active ? base : raw) }
        engineReport = [:]; engineReportText = ""
        updateReport(); sendInput()
    }

    func command(_ name: String) {
        guard ["retry", "restore", "status"].contains(name) else { return }
        if name == "restore", manual != nil {
            if let song = input?.song, let file = translationFile(song) { try? FileManager.default.removeItem(at: file) }
            manual = nil
            apply(raw)
            sendInput()
        }
        guard ready else { notice = "字幕引擎正在準備，請稍後再試。"; return }
        call("window.FoliaSubtitles.command(name)", ["name": name])
    }

    func readTranslation(videoID: String) {
        guard preferences.active, YouTubeVideo.validID(videoID) else { return }
        let baseline = raw.lines
        readTranslation(source: "YouTube 翻譯影片") { progress in
            do {
                return try await SubtitleNetwork.shared.youtubeLyrics(id: videoID, baseline: baseline)
            } catch let ccFailure as SubtitleReadError where ccFailure.code == "captions-unavailable" {
                try Task.checkCancellation()
                await progress(-1)
                do {
                    let file = try await AudioDownloadService.shared.translatedVideo(videoID)
                    defer { try? FileManager.default.removeItem(at: file) }
                    return try await YouTubeCaptionOCR.read(file, progress: progress)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let videoFailure = (error as? SubtitleReadError) ?? SubtitleReadError("video-unavailable")
                    let detail = "CC：未列出人工中文字幕軌；影片辨識：\(videoFailure.explanation)"
                    throw SubtitleReadError(videoFailure.code, detail: detail)
                }
            }
        }
    }

    func readTranslation(file: URL) {
        guard preferences.active else { return }
        readTranslation(source: "匯入影片字幕") { progress in
            try await YouTubeCaptionOCR.read(file, progress: progress)
        }
    }

    private func readTranslation(source: String, work: @escaping @Sendable (@Sendable (Double) async -> Void) async throws -> [LyricLine]) {
        guard let song = input?.song, song.durationMs > 0 else { notice = "請等目前音訊載入後再讀取翻譯字幕。"; return }
        cancelTranslationRead(); translationPreview = nil
        sourceStatus.removeValue(forKey: "ytm-manual")
        sourceDiagnostics.removeValue(forKey: "ytm-manual")
        updateReport()
        let ticket = videoRevision
        videoProgress = "正在讀取字幕軌…"
        videoTask = Task { [weak self] in
            do {
                let lines = try await work { [weak self] amount in
                    await MainActor.run { [weak self] in
                        guard let self, videoRevision == ticket else { return }
                        videoProgress = amount < 0 ? "未讀到字幕軌，正在準備辨識畫面…" : "正在辨識畫面字幕 \(Int(amount * 100))%"
                    }
                }
                guard let self, videoRevision == ticket, input?.song.id == song.id, !Task.isCancelled else { return }
                let result = Self.alignTranslation(lines, to: raw.lines)
                let timeline = LyricTimeline(lines: result.lines).prepared(for: song.durationMs / 1000)
                guard !timeline.lines.isEmpty else { throw SubtitleReadError("empty") }
                translationPreview = TranslationPreview(lines: timeline.lines, source: source, aligned: result.aligned)
                sourceStatus["ytm-manual"] = "已讀取 \(lines.count) 行；等待預覽確認。"
                videoProgress = nil; updateReport()
            } catch {
                guard let self, videoRevision == ticket, !Task.isCancelled else { return }
                videoProgress = nil
                let failure = error as? SubtitleReadError
                let message = failure?.explanation ?? "無法讀取翻譯影片的字幕。"
                notice = message
                sourceStatus["ytm-manual"] = message
                sourceDiagnostics["ytm-manual"] = failure?.detail
                updateReport()
            }
        }
    }

    func cancelTranslationRead() {
        videoRevision = UUID(); videoTask?.cancel(); videoTask = nil; videoProgress = nil
    }
    func discardTranslationPreview() { translationPreview = nil }

    func applyTranslationPreview() {
        guard let song = input?.song, let preview = translationPreview else { return }
        let saved = SavedTranslation(source: preview.source, duration: song.durationMs / 1000, title: song.title, lines: preview.lines)
        do {
            guard let file = translationFile(song) else { throw CocoaError(.fileWriteUnknown) }
            let data = try JSONEncoder().encode(saved)
            guard data.count <= 2_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch { notice = "字幕已套用，但無法保存。請確認可用空間。" }
        manual = saved; translationPreview = nil
        cancelRequests(); token = UUID().uuidString
        apply(base); updateReport(); sendInput()
    }

    private func translationFile(_ song: SubtitleSong) -> URL? {
        let key = song.originVideoID ?? (song.source + ":" + song.id)
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL.applicationSupportDirectory.appending(path: "Folia/Translations/" + name + ".json")
    }

    private func matches(_ stored: SavedTranslation, _ song: SubtitleSong) -> Bool {
        DownloadSongMatch.sameDuration(stored.duration, song.durationMs / 1000)
            && DownloadSongMatch.normalized(stored.title) == DownloadSongMatch.normalized(song.title)
    }

    private static func alignTranslation(_ donor: [LyricLine], to original: [LyricLine]) -> (lines: [LyricLine], aligned: Bool) {
        var matches: [String: [LyricLine]] = [:]
        for line in donor where line.translation != nil {
            let key = DownloadSongMatch.normalized(line.fullText)
            if key.count >= 3 { matches[key, default: []].append(line) }
        }
        var last = -1.0, anchors = 0
        let merged = original.map { line in
            var line = line
            if let options = matches[DownloadSongMatch.normalized(line.fullText)], options.count == 1,
               let candidate = options.first, candidate.startTime > last {
                last = candidate.startTime; anchors += 1; line.translation = candidate.translation
            }
            return line
        }
        return anchors >= max(3, donor.count / 3) ? (merged, true) : (donor, false)
    }

    // Keep this offline worker attached to the scene even when a full-screen player covers the library.
    fileprivate func mount(in window: UIWindow, lease: UUID) {
        guard let view = webView else { return }
        hostLease = lease
        if view.superview !== window { window.addSubview(view) }
        view.frame = CGRect(x: 1, y: window.safeAreaInsets.top + 1, width: 1, height: 1)
        if !ready { synchronize() }
    }
    fileprivate func unmount(lease: UUID) {
        guard hostLease == lease else { return }
        webView?.removeFromSuperview(); hostLease = nil
    }
    func synchronize() {
        guard !ready, engineError == nil, !probing, let view = webView, !view.isLoading, view.url?.isFileURL == true else { return }
        probing = true
        let generation = engineGeneration
        view.evaluateJavaScript("typeof window.FoliaSubtitles?.configure === 'function'") { [weak self] result, _ in
            guard let self, generation == engineGeneration else { return }
            probing = false
            guard result as? Bool == true else { return }
            markReady()
        }
    }
    func restartEngine(manual: Bool = false) {
        if manual || Date().timeIntervalSince(recoveryWindow) > 60 { recoveries = 0; recoveryWindow = Date() }
        ready = false; probing = false; engineGeneration = UUID()
        cancelRequests(); apply(preferences.active ? base : raw); token = UUID().uuidString
        updateReport()
        guard recoveries < 2, let file = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "FoliaSubtitles") else {
            engineError = "繁體字幕尚未恢復，請按「重新準備字幕」再試。"; updateReport(); return
        }
        recoveries += 1; engineError = nil
        webView?.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }
    private func markReady(replay: Bool = false) {
        guard replay || !ready else { return }
        ready = true; engineError = nil; configureEngine(); updateReport(); sendInput()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "Folia.BuiltInTraditionalLyrics.v1") }
    }
    private func configureEngine() {
        guard ready else { return }
        configurationRevision += 1
        if !preferences.active {
            cancelRequests(); apply(raw); reportJSON = Data("{}".utf8)
            sourceStatus.removeAll(); sourceDiagnostics.removeAll(); engineReport = [:]
        }
        var providers: [[String: Any]] = [
            ["providerId": "netease", "displayName": "網易雲", "configured": preferences.searchNetease, "supports": ["search": true, "lyrics": true]],
            ["providerId": "qq", "displayName": "QQ 音樂", "configured": preferences.searchQQ, "supports": ["search": true, "lyrics": true]],
            ["providerId": "ytm", "displayName": "YouTube 人工中文字幕", "configured": preferences.searchYouTube, "supports": ["search": true, "lyrics": true]],
            ["providerId": "local", "displayName": "本機歌詞", "configured": library != nil, "supports": ["search": true, "lyrics": true]],
            ["providerId": "navidrome", "displayName": "Navidrome", "configured": account != nil, "supports": ["search": true, "lyrics": true]],
            ["providerId": "lrclib", "displayName": "LRCLIB", "configured": !fixture, "supports": ["search": true, "lyrics": true]],
        ]
        if fixture { providers = [] }
        var settings = object(preferences) as? [String: Any] ?? [:]
        settings["nativeRevision"] = configurationRevision
        settings["hostVersion"] = "Folia-iOS/" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
        call("window.FoliaSubtitles.configure(settings, providers, account)",
             ["settings": settings, "providers": providers, "account": accountKey])
    }
    private func sendInput() {
        guard ready else { return }
        guard let input, !input.loading || !base.lines.isEmpty else { call("window.FoliaSubtitles.load(null)", [:]); return }
        let song = matchingSong(input.song)
        call("window.FoliaSubtitles.load(input)", ["input": ["token": token, "song": object(song) ?? [:],
            "duration": input.song.durationMs / 1000, "lines": object(base.lines) ?? [], "manual": manual != nil,
            "waitingForAudio": input.loading]])
    }
    private func call(_ script: String, _ args: [String: Any]) {
        let revision = configurationRevision
        let generation = engineGeneration
        webView?.callAsyncJavaScript(script, arguments: args, in: nil, in: .page) { [weak self] result in
            guard let self, revision == configurationRevision, generation == engineGeneration else { return }
            if case .failure = result { restartEngine() }
        }
    }
    private func object<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView === webView,
              message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" { synchronize(); return }
        if type == "cancel", let id = body["id"] as? String { tasks.removeValue(forKey: id)?.cancel(); return }
        if type == "request" { request(body); return }
        if type == "toast", let text = body["text"] as? String { notice = text; return }
        guard body["token"] as? String == token else { return }
        guard body["configurationRevision"] as? Int == configurationRevision else { return }
        if !preferences.active {
            apply(raw); updateReport()
            return
        }
        if type == "display", let lines = body["lines"], JSONSerialization.isValidJSONObject(lines),
           let data = try? JSONSerialization.data(withJSONObject: lines), data.count <= 16_000_000,
           let decoded = try? JSONDecoder().decode([LyricLine].self, from: data), decoded.count <= 20_000 {
            let cleaned = LyricTimeline(lines: decoded).prepared(for: (input?.song.durationMs ?? 0) / 1000)
            apply(cleaned.lines.isEmpty && !base.lines.isEmpty ? base : cleaned)
            updateReport()
        } else if type == "report" {
            engineReportText = body["text"] as? String ?? "目前沒有報告。"
            engineReport = body["value"] as? [String: Any] ?? [:]
            updateReport()
        }
    }

    private func matchingSong(_ song: SubtitleSong) -> SubtitleSong {
        song.source == "ytm" ? YouTubeCaptionDecoders.metadata(id: song.id, title: song.title,
            artist: song.artist, duration: song.durationMs / 1000) : song
    }
    private func updateReport() {
        let names = ["netease": "網易雲", "qq": "QQ 音樂", "ytm": "YouTube 搜尋", "ytm-manual": "YouTube 翻譯影片",
            "local": "本機", "navidrome": "Navidrome", "lrclib": "LRCLIB"]
        let states = sourceStatus.keys.sorted().map { "\(names[$0] ?? $0)：\(sourceStatus[$0] ?? "")" }
        let details = sourceDiagnostics.keys.sorted().map { "\(names[$0] ?? $0)：\(sourceDiagnostics[$0] ?? "")" }
        let engine = engineError ?? (preferences.active ? (ready ? "已就緒" : "準備中") : "已停用")
        let song = input.map { "\($0.song.title) · \($0.song.artist)" } ?? "目前沒有歌曲"
        let translated = timeline.lines.filter { $0.translation?.isEmpty == false || $0.extra["displayTranslation"] != nil }.count
        let summary = ["繁體字幕：\(engine)", "歌曲：\(song)",
            "原字幕 \(raw.lines.count) 行 · 顯示 \(timeline.lines.count) 行 · 附譯文 \(translated) 行",
            manual.map { "已套用：\($0.source)" } ?? (input?.loading == true ? "等待目前音源與原字幕。" : "")]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let readable = engineReportText.components(separatedBy: "── 完整結構化紀錄 ──").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        reportText = summary + (states.isEmpty ? "" : "\n\n來源讀取\n" + states.joined(separator: "\n"))
            + (readable.isEmpty ? "" : "\n\n" + String(readable.prefix(12_000)))
            + (details.isEmpty ? "" : "\n\n回覆結構\n" + details.joined(separator: "\n"))
        var report = engineReport
        report["iosSummary"] = summary
        report["iosSources"] = sourceStatus
        report["iosResponseDiagnostics"] = sourceDiagnostics
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { reportJSON = data }
    }

    private func cancelRequests() {
        for task in tasks.values { task.cancel() }; tasks.removeAll()
        candidates.removeAll(); candidateOrder.removeAll()
    }
    private func apply(_ next: LyricTimeline) {
        guard timeline.lines != next.lines else { return }
        timeline = next; revision = UUID()
    }
    private func register(_ song: SubtitleSong, _ value: Candidate) -> [String: Any] {
        let ref = UUID().uuidString; candidates[ref] = value; candidateOrder.append(ref)
        while candidateOrder.count > 192 { candidates.removeValue(forKey: candidateOrder.removeFirst()) }
        var result = object(song) as? [String: Any] ?? [:]; result["ref"] = ref
        return result
    }

    private func request(_ body: [String: Any]) {
        guard preferences.active, let id = body["id"] as? String, tasks[id] == nil,
              tasks.count < 4, let method = body["method"] as? String,
              let params = body["params"] as? [String: Any], let provider = params["providerId"] as? String else { return }
        let requestAccount = accountKey
        let requestToken = token
        let requestPreferences = preferences
        let currentSong = input.map { matchingSong($0.song) }
        let originalLines = raw.lines
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            var value: [String: Any] = [:]
            var failure: [String: Any]?
            do {
                if method == "search", let query = params["query"] as? String, !query.isEmpty, query.count <= 400 {
                    var songs: [[String: Any]] = []
                    if provider == "local", let library {
                        let terms = query.split(whereSeparator: \.isWhitespace)
                        let tracks = library.tracks.filter { track in track.lyricFile != nil && terms.allSatisfy {
                            (track.title + " " + (track.artist ?? "")).localizedStandardContains(String($0))
                        } }.prefix(8)
                        songs = tracks.map { register(SubtitleSong(id: $0.id, source: provider, title: $0.title,
                            artist: $0.artist ?? "", durationMs: ($0.duration ?? 0) * 1000), .local($0)) }
                    } else if provider == "navidrome", let account {
                        let tracks = try await NavidromeClient(account: account).search(query, limit: 8)
                        try Task.checkCancellation()
                        songs = tracks.prefix(8).map { register(SubtitleSong(id: $0.id, source: provider, title: $0.title,
                            artist: $0.artist ?? "", durationMs: ($0.duration ?? 0) * 1000), .navidrome($0)) }
                    } else if ["lrclib", "netease", "qq", "ytm"].contains(provider) {
                        let records = try await SubtitleNetwork.shared.search(query, provider: provider,
                            netease: requestPreferences.neteaseAPI, current: currentSong)
                        try Task.checkCancellation()
                        songs = records.map { register($0.song, .record($0)) }
                    } else { throw SubtitleReadError("unsupported") }
                    value = ["items": songs]
                    if requestToken == token, requestAccount == accountKey {
                        sourceStatus[provider] = "找到 \(songs.count) 個候選；由插件核對歌曲版本。"
                    }
                } else if method == "lyrics", let ref = params["ref"] as? String, let candidate = candidates[ref] {
                    let lines: [LyricLine]
                    switch candidate {
                    case .local(let track): lines = try await library?.lyrics(for: track)?.lines ?? []
                    case .navidrome(let track):
                        guard let account else { throw SubtitleReadError("not-signed-in") }
                        lines = try await NavidromeClient(account: account).subtitleLyrics(for: track)?.lines ?? []
                    case .record(let record):
                        guard record.song.source == provider else { throw SubtitleReadError("invalid-response") }
                        lines = try await SubtitleNetwork.shared.lyrics(record, netease: requestPreferences.neteaseAPI, original: originalLines, current: currentSong)
                    }
                    value = ["lines": object(lines) ?? []]
                    if requestToken == token, requestAccount == accountKey {
                        sourceStatus[provider] = "已讀取 \(lines.count) 行同步字幕；是否套用以插件診斷為準。"
                    }
                } else { throw SubtitleReadError("invalid-response") }
            } catch {
                var code = Task.isCancelled ? "aborted" : (error as? SubtitleReadError)?.code ?? "network"
                if let error = error as? NavidromeError {
                    switch error {
                    case .serverError(40), .serverError(41): code = "not-signed-in"
                    default: break
                    }
                }
                failure = ["code": code, "message": code]
                if !Task.isCancelled, requestToken == token, requestAccount == accountKey {
                    sourceStatus[provider] = SubtitleReadError(code).explanation
                    if let detail = (error as? SubtitleReadError)?.detail { sourceDiagnostics[provider] = detail }
                }
            }
            guard !Task.isCancelled, requestAccount == accountKey, requestToken == token else { tasks.removeValue(forKey: id); return }
            tasks.removeValue(forKey: id)
            if failure == nil { sourceDiagnostics.removeValue(forKey: provider) }
            updateReport()
            call("window.FoliaSubtitles.resolve(id, result, error)", ["id": id, "result": value, "error": failure.map { $0 as Any } ?? NSNull()])
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        restartEngine()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The one-shot ready message can precede the committed frame URL; verify the actual API too.
        synchronize()
    }
}

struct SubtitleEngineAnchor: UIViewRepresentable {
    let controller: SubtitleController
    func makeUIView(context: Context) -> AnchorView { AnchorView(controller) }
    func updateUIView(_ view: AnchorView, context: Context) {
        if let window = view.window { controller.mount(in: window, lease: view.lease) }
    }
    static func dismantleUIView(_ view: AnchorView, coordinator: Void) { view.owner?.unmount(lease: view.lease) }
    final class AnchorView: UIView {
        weak var owner: SubtitleController?
        let lease = UUID()
        init(_ owner: SubtitleController) { self.owner = owner; super.init(frame: .zero); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { return nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { owner?.mount(in: window, lease: lease) }
        }
    }
}

@MainActor private final class SubtitleMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: SubtitleController?
    init(_ owner: SubtitleController) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
}
