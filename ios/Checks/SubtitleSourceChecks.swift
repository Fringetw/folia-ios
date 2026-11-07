import Foundation

enum SubtitleSourceChecks {
    static func run() throws {
        let old = try JSONDecoder().decode(SubtitlePreferences.self, from: Data(#"{"enabled":false,"target":"t","convertOriginal":false,"neteaseAPI":"https://example.com/music"}"#.utf8))
        precondition(!old.enabled && !old.convertOriginal && old.target == "t")
        precondition(old.searchNetease && old.searchQQ && old.searchYouTube)
        let roundTrip = try JSONDecoder().decode(SubtitlePreferences.self, from: JSONEncoder().encode(old))
        precondition(roundTrip == old)
        let form = String(decoding: SubtitleNetwork.neteaseForm("A+B & 雨"), as: UTF8.self)
        precondition(form.contains("A%2BB%20%26%20") && form.contains("type=1") && form.contains("limit=8"))
        let queryURL = YouTubeCaptionDecoders.searchURL("A+B & 雨")
        let queryParts = URLComponents(url: queryURL, resolvingAgainstBaseURL: false)!
        precondition(queryParts.percentEncodedQuery?.contains("A%2BB") == true)
        precondition(queryParts.host == "www.youtube.com" && queryParts.path == "/results")
        precondition(queryParts.queryItems?.first { $0.name == "sp" }?.value == "EgIoAQ%3D%3D")
        precondition(queryParts.queryItems?.first { $0.name == "search_query" }?.value == "A+B & 雨 中文字幕")
        let broad = URLComponents(url: YouTubeCaptionDecoders.searchURL("JANE DOE 米津玄師", requireCaptions: false), resolvingAgainstBaseURL: false)!
        precondition(!broad.queryItems!.contains { $0.name == "sp" })
        let jane = "【AMV 繁中/日歌詞】鏈鋸人:蕾潔篇ED「JANE DOE」- 米津玄師Kenshi Yonezu&宇多田ヒカルHikaru Utada lyrics Music Video"
        precondition(YouTubeCaptionDecoders.isTranslatedUpload(jane))
        let translated = YouTubeCaptionDecoders.metadata(id: "t8HwSSH5Hes", title: jane, artist: "Mark Chong", duration: 236)
        precondition(translated.title == "JANE DOE" && translated.artist == "米津玄師 / 宇多田ヒカル")
        let ccTitle = "【鏈鋸人】鏈鋸人劇場版-『鏈鋸人-蕾潔篇』片尾曲ED「JANE DOE」 米津玄師&宇多田光 |完整版|CC字幕|中日字幕 【4K】"
        let cc = YouTubeCaptionDecoders.metadata(id: "RCXjG2tsojs", title: ccTitle, artist: "真尋醬是全世界最可愛的♡", duration: 236)
        precondition(cc.title == "JANE DOE" && cc.artist == "米津玄師 / 宇多田光")
        precondition(YouTubeCaptionDecoders.isTranslatedUpload(ccTitle))
        let originalSong = YouTubeCaptionDecoders.metadata(id: "sPLqsLsooJY",
            title: "米津玄師, 宇多田ヒカル Kenshi Yonezu, Hikaru Utada -  JANE DOE",
            artist: "Kenshi Yonezu  米津玄師和Hikaru Utada", duration: 247)
        precondition(originalSong.title == "JANE DOE" && originalSong.artist == "米津玄師 / 宇多田ヒカル", "Unexpected original video metadata: \(originalSong.title) / \(originalSong.artist)")
        let originalRecord = SubtitleRecord(song: originalSong)
        let ccPage = """
        var ytInitialData = {"contents":[{"videoRenderer":{
          "videoId":"RCXjG2tsojs","title":{"simpleText":"\(ccTitle)"},
          "ownerText":{"simpleText":"真尋醬是全世界最可愛的♡"},"lengthText":{"simpleText":"3:56"}
        }}]};
        """
        let ccRecords = try YouTubeCaptionDecoders.search(ccPage)
        precondition(ccRecords.count == 1)
        let ccRecord = ccRecords[0]
        precondition(ccRecord.song == cc && ccRecord.translatedCCHint && ccRecord.uploader == "真尋醬是全世界最可愛的♡")
        let broadRecord = SubtitleRecord(song: translated, translatedVideo: true)
        let ranked = YouTubeCaptionDecoders.rankedSearchResults(withCC: [broadRecord, originalRecord, ccRecord],
            broad: [originalRecord, broadRecord])
        precondition(ranked.map(\.song.id) == ["RCXjG2tsojs", "t8HwSSH5Hes", "sPLqsLsooJY"])
        let timed = (0..<8).map { i in LyricLine(startTime: Double(i) * 2, endTime: Double(i) * 2 + 1.8, fullText: "Line \(i)") }
        let shifted = timed.map { LyricLine(startTime: $0.startTime + 0.55, endTime: $0.endTime + 0.55, fullText: "中文譯文") }
        let paired = SubtitleSourceDecoders.attach(timed, translations: shifted)
        precondition(paired.allSatisfy { $0.translation == "中文譯文" })
        let broken = LyricLine(startTime: 100, endTime: 105, fullText: "Bad tail")
        let kept = LyricTimeline(lines: paired + [broken]).prepared(for: 16)
        precondition(kept.lines.count == 8 && kept.lines.last?.translation == "中文譯文")
        let safeReply = SubtitleSourceDecoders.replySummary(Data(#"{"code":200,"result":null,"token":"MUST_NOT_LEAK","lrc":{"lyric":"PRIVATE_LYRIC"}}"#.utf8))
        precondition(safeReply.contains("result=null") && safeReply.contains("code=200") && !safeReply.contains("MUST_NOT_LEAK") && !safeReply.contains("PRIVATE_LYRIC"))
        let netease = try SubtitleSourceDecoders.neteaseSearch(Data(#"{"code":200,"result":{"songs":[{"id":42,"name":"Test","ar":[{"name":"Artist"}],"dt":60000}]}}"#.utf8))
        precondition(netease.first?.song.id == "42" && netease.first?.song.durationMs == 60000)
        let words = try SubtitleSourceDecoders.neteaseLyrics(Data(#"{"code":200,"lrc":{"lyric":"[00:01]Blue sky\n[00:06]Still here"},"tlyric":{"lyric":"[00:01.10]蓝色天空\n[00:08]錯位"},"romalrc":{"lyric":"[00:01]blu skai"}}"#.utf8))
        precondition(words[0].fullText == "Blue sky" && words[0].translation == "蓝色天空" && words[0].romanization == "blu skai")
        precondition(words[1].translation == nil)
        let qq = try SubtitleSourceDecoders.qqSearch(Data(#"{"code":0,"data":{"song":{"list":[{"songid":7,"songname":"A &amp; B","singer":[{"name":"歌手 (かしゅ)"}],"interval":60}]}}}"#.utf8))
        precondition(qq[0].song.title == "A & B" && qq[0].song.artist == "歌手" && qq[0].song.durationMs == 60000)
        let payload: [String: Any] = ["code": 0, "request": ["code": 0, "data": ["crypt": 0, "qrc": 0,
            "lyric": Data("[00:01]Blue sky".utf8).base64EncodedString(), "trans": Data("[00:01]蓝色天空".utf8).base64EncodedString()]]]
        let qqLines = try SubtitleSourceDecoders.qqLyrics(JSONSerialization.data(withJSONObject: payload))
        precondition(qqLines.first?.translation == "蓝色天空")
        for code in [301, 401, 429, 2001, 500] {
            do { try SubtitleSourceDecoders.check(code, success: 0); preconditionFailure("Provider refusal became success") }
            catch let error as SubtitleReadError {
                precondition(error.code == ([301, 401].contains(code) ? "not-signed-in" : [429, 2001].contains(code) ? "rate-limited" : "unavailable"))
            }
        }
        precondition(SubtitleSourceDecoders.entities("&#x98A8; &amp; &#38642;") == "風 & 雲")
        let search = #"var ytInitialData = {"estimatedResults":"1","contents":[{"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"【中日字幕】Artist - Song (Live)"}]},"ownerText":{"runs":[{"text":"Translator"}]},"lengthText":{"simpleText":"3:45"}}}]};"#
        let video = try YouTubeCaptionDecoders.search(search)[0].song
        precondition(video.id == "abcdefghijk" && video.title == "Song (Live)" && video.artist == "Artist" && video.durationMs == 225000)
        let official = YouTubeCaptionDecoders.metadata(id: "abcdefghijk", title: "米津玄師 Kenshi Yonezu - Lemon", artist: "米津玄師", duration: 256)
        precondition(official.artist == "米津玄師" && official.title == "Lemon")
        let multilingual = YouTubeCaptionDecoders.metadata(id: "abcdefghijk", title: "米津玄師 Kenshi Yonezu - Lemon", artist: "Kenshi Yonezu 米津玄師", duration: 256)
        precondition(multilingual.artist == "米津玄師" && multilingual.title == "Lemon")
        let unrelated = YouTubeCaptionDecoders.metadata(id: "abcdefghijk", title: "米津玄師 Kenshi Yonezu - Lemon", artist: "Another Performer 米津玄師", duration: 256)
        precondition(unrelated.artist == "米津玄師 Kenshi Yonezu")
        for code in [405, 460, -460, 403, 451] {
            do { try SubtitleSourceDecoders.check(code, success: 200); preconditionFailure("Platform restriction ignored") }
            catch let error as SubtitleReadError {
                precondition(error.code == (code == 405 ? "rate-limited" : [403,451].contains(code) ? "region-restricted" : "verification-required"))
            }
        }
        let escaped = #"window["ytInitialData"]={"text":"quoted \" } text","estimatedResults":"0"};"#
        let empty = try YouTubeCaptionDecoders.search(escaped)
        precondition(empty.isEmpty)
        let watch = #"var ytInitialPlayerResponse = {"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"abcdefghijk"},"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[{"languageCode":"zh-Hant","baseUrl":"https://www.youtube.com/api/timedtext?v=abcdefghijk&lang=zh-Hant"},{"languageCode":"zh","kind":"asr","baseUrl":"https://www.youtube.com/api/timedtext?v=abcdefghijk&lang=zh&kind=asr"},{"languageCode":"en","baseUrl":"https://www.youtube.com/api/timedtext?v=abcdefghijk&lang=en"},{"languageCode":"zh","baseUrl":"https://evil.example/api/timedtext"},{"languageCode":"zh","baseUrl":"https://www.youtube.com/api/timedtext?v=abcdefghijk&tlang=zh"}]}}};"#
        let tracks = try YouTubeCaptionDecoders.tracks(watch, videoID: "abcdefghijk")
        precondition(tracks.count == 3 && tracks[0].chinese && !tracks[0].automatic && tracks[1].automatic)
        precondition(tracks.allSatisfy { $0.url.query?.contains("fmt=json3") == true })
        let signedWatch = watch.replacingOccurrences(of: "lang=zh-Hant", with: "lang=zh-Hant&signature=a%2Bb")
        let config = #"ytcfg.set({"INNERTUBE_CONTEXT":{"client":{"clientName":"WEB","clientVersion":"2.20261107.00.00"}},"INNERTUBE_API_KEY":"public-fixture-api-key","PLAYER_JS_URL":"/s/player/example/base.js","VISITOR_DATA":"anonymous-fixture"});"#
        let earlierConfig = #"ytcfg.set('EXPERIMENT_FLAGS', {}); ytcfg.set({"loaded":true}); ytcfg.set({unquoted:true});"#
        let web = try YouTubeCaptionDecoders.webCaptionRequest(earlierConfig + config + watch, videoID: "abcdefghijk")
        precondition(web.script.absoluteString == "https://www.youtube.com/s/player/example/base.js")
        precondition(web.endpoint.path == "/youtubei/v1/player" && web.headers["X-Goog-Visitor-Id"] == "anonymous-fixture")
        let stamp = try YouTubeCaptionDecoders.signatureTimestamp(Data("player={signatureTimestamp: 12345};".utf8))
        let body = try SubtitleSourceDecoders.object(web.body(signatureTimestamp: stamp))
        precondition(body["videoId"] as? String == "abcdefghijk" && stamp == 12345)
        precondition(body["contentCheckOk"] == nil && body["racyCheckOk"] == nil)
        let freshData = try JSONSerialization.data(withJSONObject: YouTubeCaptionDecoders.playerResponse(watch, videoID: "abcdefghijk"))
        let freshTracks = try YouTubeCaptionDecoders.tracks(playerData: freshData, videoID: "abcdefghijk")
        precondition(freshTracks == tracks)
        let unrelatedScript = config.replacingOccurrences(of: "/s/player/example/base.js", with: "https://example.com/s/player/example/base.js")
        do {
            _ = try YouTubeCaptionDecoders.webCaptionRequest(unrelatedScript + watch, videoID: "abcdefghijk")
            preconditionFailure("Player script outside the YouTube origin was accepted")
        } catch is SubtitleReadError {}
        let signedTracks = try YouTubeCaptionDecoders.tracks(signedWatch, videoID: "abcdefghijk")
        precondition(signedTracks[0].url.absoluteString.contains("signature=a%2Bb"))
        for raw in ["http://www.youtube.com/api/timedtext", "https://youtube.com.evil.example/api/timedtext",
                    "https://www.youtube.com@evil.example/api/timedtext", "https://www.youtube.com/watch"] {
            precondition(!YouTubeCaptionDecoders.allowedCaptionURL(URL(string: raw)))
        }
        let original = try YouTubeCaptionDecoders.cues(Data(#"{"events":[{"tStartMs":1000,"dDurationMs":4000,"segs":[{"utf8":"Blue "},{"utf8":"sky"}]},{"tStartMs":6000,"dDurationMs":4000,"segs":[{"utf8":"Still here"}]}]}"#.utf8))
        precondition(original[0].fullText == "Blue sky" && original[0].endTime == 5)
        let chinese = try YouTubeCaptionDecoders.cues(Data(#"{"events":[{"tStartMs":1000,"dDurationMs":4000,"segs":[{"utf8":"藍色天空"}]},{"tStartMs":6100,"dDurationMs":4000,"segs":[{"utf8":"還在這裡"}]}]}"#.utf8))
        let dual = try YouTubeCaptionDecoders.cues(Data(#"{"events":[{"tStartMs":1000,"dDurationMs":4000,"segs":[{"utf8":"Blue sky\n藍色天空"}]},{"tStartMs":6000,"dDurationMs":4000,"segs":[{"utf8":"まだここにいる\n還在這裡"}]}]}"#.utf8), chinese: true)
        precondition(dual[0].fullText == "Blue sky" && dual[0].translation == "藍色天空")
        precondition(dual[1].fullText == "まだここにいる" && dual[1].translation == "還在這裡")
        let wrap = try YouTubeCaptionDecoders.cues(Data(#"{"events":[{"tStartMs":1000,"dDurationMs":4000,"segs":[{"utf8":"一行中文\n另一行中文"}]}]}"#.utf8), chinese: true)
        precondition(wrap[0].translation == nil && wrap[0].fullText == "一行中文\n另一行中文")
        let pairedDual = YouTubeCaptionDecoders.bilingual(chinese: dual, original: original)
        precondition(pairedDual[0].translation == "藍色天空")
        let combined = YouTubeCaptionDecoders.bilingual(chinese: chinese, original: original)
        precondition(combined.map(\.translation) == ["藍色天空", "還在這裡"] && combined[1].startTime == 6)
        precondition(YouTubeCaptionDecoders.bilingual(chinese: chinese, original: nil) == chinese)
        let sameVideo = YouTubeCaptionDecoders.bilingual(chinese: chinese, original: nil, sameVideoBaseline: original)
        precondition(sameVideo[0].fullText == "Blue sky" && sameVideo[0].translation == "藍色天空")
        let offsetChinese = chinese.map { LyricLine(startTime: $0.startTime + 3, endTime: $0.endTime + 3, fullText: $0.fullText) }
        precondition(YouTubeCaptionDecoders.bilingual(chinese: offsetChinese, original: nil, sameVideoBaseline: original) == offsetChinese)
        do { _ = try YouTubeCaptionDecoders.tracks(watch, videoID: "otherID1234"); preconditionFailure("Wrong video response accepted") }
        catch is SubtitleReadError {}
        do { _ = try YouTubeCaptionDecoders.embeddedObject("unusual traffic /sorry/", name: "ytInitialData"); preconditionFailure("Challenge became no results") }
        catch let error as SubtitleReadError { precondition(error.code == "verification-required") }
        print("PASS: subtitle source migration, NetEase / QQ translations, YouTube manual tracks, pairing, refusal and URL checks")
    }
}
