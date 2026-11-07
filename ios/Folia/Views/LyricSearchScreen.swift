import SwiftUI
import UniformTypeIdentifiers

// All lyric discovery is in one sheet; conversion preferences remain under Settings.
struct LyricSearchScreen: View {
    let subtitles: SubtitleController
    @State var title: String
    @State var artist: String
    var player: PlaybackModel? = nil
    let choose: (LyricSearchRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var records: [LyricSearchRecord] = []
    @State private var loading = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var showingPreferences = false
    @State private var translationLink = ""
    @State private var videos: [SubtitleRecord] = []
    @State private var searchingVideos = false
    @State private var videoSearch: Task<Void, Never>?
    @State private var videoError: String?
    @State private var importingVideo = false

    var body: some View {
        NavigationStack {
            Form {
                chineseSection
                videoSection
                offsetSection
                lrclibSection
                recordsSection
            }
            .navigationTitle("尋找歌詞").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() }.accessibilityIdentifier("closeLyricSearch") } }
            .toolbar { ToolbarItem(placement: .primaryAction) {
                Button { showingPreferences = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("繁體字幕設定")
            } }
            .buttonStyle(FoliaPressStyle())
        }
        .onDisappear { task?.cancel(); videoSearch?.cancel(); subtitles.cancelTranslationRead() }
        .fileImporter(isPresented: $importingVideo, allowedContentTypes: [.movie]) { result in
            if case .success(let url) = result { subtitles.readTranslation(file: url) }
        }
        .onChange(of: title) { _, _ in cancelSearch() }
        .onChange(of: artist) { _, _ in cancelSearch() }
        .sheet(isPresented: $showingPreferences) { SubtitleSettingsScreen(subtitles: subtitles) }
        .alert("歌詞", isPresented: Binding(get: { subtitles.notice != nil }, set: { if !$0 { subtitles.notice = nil } })) {
            Button("好", role: .cancel) { subtitles.notice = nil }
        } message: { Text(subtitles.notice ?? "") }
    }

    private var chineseSection: some View {
        Section("目前歌曲的中文字幕") {
            Button("尋找中文字幕") { subtitles.command("retry") }
                .accessibilityIdentifier("findChineseLyrics")
                .disabled(!subtitles.preferences.active)
            Text("依序搜尋已啟用的網易雲、QQ 音樂與 YouTube 來源，核對版本和時間後補上中文。來源開關在「設定 → 繁體字幕」。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(["netease", "qq", "ytm"], id: \.self) { provider in
                if let status = subtitles.sourceStatus[provider] {
                    LabeledContent(provider == "netease" ? "網易雲" : provider == "qq" ? "QQ 音樂" : "YouTube", value: status)
                        .font(.caption)
                }
            }
            Button("查看字幕來源與中文覆蓋率") { subtitles.command("status") }
            Button("還原這首歌的原字幕") { subtitles.command("restore") }
        }
    }

    private var videoSection: some View {
        Section("YouTube 翻譯影片") {
            Button(searchingVideos ? "正在找翻譯影片…" : "依目前歌曲找翻譯影片", systemImage: "magnifyingglass") {
                searchVideos()
            }.disabled(searchingVideos || !subtitles.preferences.active)
            ForEach(videos, id: \.song.id) { record in
                Button {
                    subtitles.readTranslation(videoID: record.song.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.song.title)
                        Text(record.song.artist + " · " + playbackTime(record.song.durationMs / 1000))
                            .font(.caption).foregroundStyle(.secondary)
                        if let uploader = record.uploader {
                            Text(record.translatedCCHint ? uploader + " · 標有 CC" : uploader)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.disabled(subtitles.videoProgress != nil)
            }
            TextField("貼上已有中文字幕的影片連結", text: $translationLink)
                .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("translatedVideoURL")
            Button("讀取這部影片的字幕") {
                if let id = YouTubeVideo.identifier(from: translationLink) { subtitles.readTranslation(videoID: id) }
            }.disabled(YouTubeVideo.identifier(from: translationLink) == nil || subtitles.videoProgress != nil || !subtitles.preferences.active)
            Button("從「檔案」選擇影片來辨識") { importingVideo = true }
                .disabled(subtitles.videoProgress != nil || !subtitles.preferences.active)
            if let progress = subtitles.videoProgress {
                ProgressView(progress)
                Button("停止讀取", role: .cancel) { subtitles.cancelTranslationRead() }
            }
            if let videoError { Text(videoError).font(.footnote).foregroundStyle(.orange) }
            if let preview = subtitles.translationPreview {
                Text("讀到 \(preview.lines.count) 行 · " + (preview.aligned ? "已對齊原詞" : "採影片時間，可能需要校正"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(preview.lines.prefix(4).enumerated()), id: \.offset) { _, line in
                    LabeledContent(playbackTime(line.startTime), value: line.translation ?? line.fullText)
                }
                Button("套用這份字幕") { subtitles.applyTranslationPreview() }
                Button("取消預覽", role: .cancel) { subtitles.discardTranslationPreview() }
            }
            Text("先讀影片已有的人工字幕軌；若文字印在畫面上，會嘗試在 iPhone 上辨識。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var offsetSection: some View {
        if let player {
            Section("校正歌詞時間") {
                HStack {
                    Button("延後 0.1 秒") { player.adjustLyrics(by: -0.1) }
                    Spacer()
                    Text(String(format: "%+.1f 秒", player.lyricOffset)).monospacedDigit()
                    Spacer()
                    Button("提前 0.1 秒") { player.adjustLyrics(by: 0.1) }
                }.buttonStyle(.borderless)
                Button("重設為原本時間") { player.adjustLyrics(by: -player.lyricOffset) }
            }
        }
    }

    private var lrclibSection: some View {
        Section("尋找其他同步歌詞版本") {
            TextField("歌名", text: $title)
            TextField("歌手", text: $artist)
            Button(loading ? "正在尋找…" : "搜尋 LRCLIB") { search() }.disabled(loading || title.trimmingCharacters(in: .whitespaces).isEmpty)
            if let error { Text(error).foregroundStyle(.orange) }
        }
    }

    private var recordsSection: some View {
        Section("選擇與目前音訊相同的版本") {
            ForEach(records) { record in
                Button { choose(record); dismiss() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.trackName).foregroundStyle(.primary)
                        Text("\(record.artistName) · \(record.albumName) · \(playbackTime(record.duration))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(record.syncedLyrics?.split(separator: "\n").prefix(2).joined(separator: "\n") ?? "")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
    }

    private func searchVideos() {
        videoSearch?.cancel(); searchingVideos = true; videoError = nil; videos = []
        let query = subtitles.currentSearchTerms ?? (title, artist)
        videoSearch = Task {
            defer { if !Task.isCancelled { searchingVideos = false } }
            do {
                let found = try await SubtitleNetwork.shared.translationVideos(title: query.0, artist: query.1)
                guard !Task.isCancelled else { return }
                videos = found
                if found.isEmpty { videoError = "沒有找到標示中文翻譯的影片，可以直接貼上連結。" }
            } catch {
                guard !Task.isCancelled else { return }
                videoError = (error as? SubtitleReadError)?.explanation ?? "YouTube 搜尋暫時無法讀取。"
            }
        }
    }
    private func cancelSearch() { task?.cancel(); loading = false; records = []; error = nil }
    private func search() {
        task?.cancel(); loading = true; error = nil; records = []
        let title = title, artist = artist
        task = Task {
            do {
                let found = try await OnlineLyrics.shared.search(title: title, artist: artist)
                guard !Task.isCancelled else { return }
                records = found; loading = false
                if found.isEmpty { error = "找不到同步歌詞，可調整歌名或歌手，或附加自己的 LRC／FIA。" }
            } catch {
                guard !Task.isCancelled else { return }
                loading = false; self.error = "歌詞服務未回應，請稍後再試。"
            }
        }
    }
}
