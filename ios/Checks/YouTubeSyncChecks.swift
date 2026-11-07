import Foundation

enum YouTubeSyncChecks {
    static func run() throws {
        precondition(PlatformLibrary.isoDuration("PT1H2M3S") == 3723)
        precondition(PlatformLibrary.isoDuration("PT4M0.5S") == 240.5)
        precondition(PlatformLibrary.isoDuration("PT") == nil)
        let song = SyncedYouTubeSong(LibraryEntry(id: "row-1", title: "米津玄師 - LOSER (Official Music Video)",
            subtitle: "米津玄師", url: URL(string: "https://music.youtube.com/watch?v=M7lc1UVf-VE")!, duration: 244))!
        precondition(DownloadSongMatch.matches(song, title: "LOSER", artists: ["米津玄師"], duration: 243.8))
        precondition(!DownloadSongMatch.matches(song, title: "LOSER", artists: ["翻唱者"], duration: 244))
        precondition(!DownloadSongMatch.matches(song, title: "LOSER (Live)", artists: ["米津玄師"], duration: 244))
        precondition(!DownloadSongMatch.matches(song, title: "LOSER", artists: ["米津玄師"], duration: 30))
        precondition(!DownloadSongMatch.matches(song, title: "LOSER", artists: ["米津玄師"], duration: nil))
        precondition(DownloadSongMatch.safeAudioURL("http://example.com/song.mp3") == nil)
        precondition(DownloadSongMatch.safeAudioURL("https://user:pass@example.com/song.mp3") == nil)

        let duet = SyncedYouTubeSong(LibraryEntry(id: "row-jane-doe",
            title: "米津玄師, 宇多田ヒカル Kenshi Yonezu, Hikaru Utada -  JANE DOE",
            subtitle: "Kenshi Yonezu  米津玄師和Hikaru Utada",
            url: URL(string: "https://music.youtube.com/watch?v=sPLqsLsooJY")!, duration: 247))!
        precondition(DownloadSongMatch.matches(duet, title: "JANE DOE", artists: ["米津玄師", "宇多田ヒカル"], duration: 236.007))
        precondition(DownloadSongMatch.matches(duet, title: "JANE DOE", artists: ["米津玄師", "宇多田光"], duration: 235))
        precondition(!DownloadSongMatch.matches(duet, title: "JANE DOE", artists: ["米津玄師", "另一位歌手"], duration: 236))
        precondition(!DownloadSongMatch.matches(duet, title: "JANE DOE", artists: ["米津玄師", "宇多田光"], duration: 30))
        precondition(!DownloadSongMatch.matches(duet, title: "JANE DOE (Live)", artists: ["米津玄師", "宇多田光"], duration: 236))
        precondition(!DownloadSongMatch.matches(duet, title: "其他歌曲", artists: ["米津玄師", "宇多田光"], duration: 236))

        let recording = try DownloadSourceDecoders.search(Data(#"{"code":200,"result":{"songs":[{"id":1,"name":"LOSER","ar":[{"name":"米津玄師"}],"dt":244000},{"id":2,"name":"LOSER (Remix)","ar":[{"name":"米津玄師"}],"dt":244000}]}}"#.utf8), for: song)
        precondition(recording.count == 1 && recording[0].id == 1)
        let kawaki = SyncedYouTubeSong(LibraryEntry(id: "row-alias", title: "カワキヲアメク", subtitle: "美波 - Topic",
            url: URL(string: "https://music.youtube.com/watch?v=M7lc1UVf-VE")!, duration: 252))!
        precondition(DownloadSongMatch.matches(kawaki, title: "カワキヲアメク (声嘶力竭)", artists: ["美波 (みなみ)"], duration: 251))
        precondition(!DownloadSongMatch.matches(kawaki, title: "カワキヲアメク (Piano Version)", artists: ["美波"], duration: 251))
        let full = #"{"code":200,"data":[{"id":1,"code":200,"url":"http://m7.music.126.net/song.flac","type":"flac","br":900000,"time":244000,"freeTrialInfo":null}]}"#
        let audio = try DownloadSourceDecoders.audio(Data(full.utf8), recording: recording[0])!
        precondition(audio.lossless && audio.url.scheme == "https")
        let preview = full.replacingOccurrences(of: "\"freeTrialInfo\":null", with: "\"freeTrialInfo\":{\"start\":0,\"end\":30}")
        let rejectedPreview = try DownloadSourceDecoders.audio(Data(preview.utf8), recording: recording[0])
        precondition(rejectedPreview == nil)
        let short = try DownloadSourceDecoders.audio(Data(full.replacingOccurrences(of: "244000", with: "30000").utf8), recording: recording[0])
        precondition(short == nil)
        let impostor = try DownloadSourceDecoders.audio(Data(full.replacingOccurrences(of: "m7.music.126.net", with: "m7.music.126.net.example.com").utf8), recording: recording[0])
        precondition(impostor == nil)
        let mp3 = DownloadAudioCandidate(url: audio.url, title: "LOSER", artist: "米津玄師", duration: 244,
            format: "mp3", bitrate: 320000, source: "測試")
        precondition(DownloadAudioCandidate.preferred(audio, mp3))
        precondition(!DownloadAudioCandidate.preferred(mp3, audio))

        let qq = try DownloadSourceDecoders.qqSearch(Data(#"{"code":0,"data":{"song":{"list":[{"songmid":"S1","strMediaMid":"M1","songid":7,"songname":"LOSER","singer":[{"name":"米津玄師"}],"interval":244}]}}}"#.utf8), for: song)
        precondition(qq.count == 1)
        let vkeys = #"{"code":0,"req_0":{"code":0,"data":{"sip":["http://dl.stream.qqmusic.qq.com/"],"midurlinfo":[{"songmid":"S1","filename":"F000M1.flac","purl":"F000M1.flac?vkey=public","result":0},{"songmid":"S1","filename":"M800M1.mp3","purl":"M800M1.mp3?vkey=encrypted","result":0,"ekey":"encrypted"},{"songmid":"S1","filename":"M500M1.mp3","purl":"M500other.mp3?vkey=wrong","result":0}]}}}"#
        let accepted = try DownloadSourceDecoders.qqAudio(Data(vkeys.utf8), recording: qq[0])
        precondition(accepted.count == 1 && accepted[0].lossless && accepted[0].recording?.id == "7")

        var snapshot = YouTubeSyncSnapshot()
        snapshot.choice = .liked; snapshot.songs = [song]
        snapshot.bindings[song.videoID] = YouTubeAudioBinding(trackID: "local-id", quality: "FLAC")
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(YouTubeSyncSnapshot.self, from: data)
        precondition(decoded == snapshot && decoded.choice?.collection == .liked)
        precondition(!String(decoding: data, as: UTF8.self).contains("music.126.net"))
        let second = SyncedYouTubeSong(LibraryEntry(id: "row-2", title: "Next", subtitle: "Artist",
            url: URL(string: "https://music.youtube.com/watch?v=abcdefghijk")!, duration: 240))!
        let added = SyncedYouTubeSong(local: .demo)
        var edited = decoded
        edited.edits = ["liked": FoliaPlaylistEdits(name: "本機編輯", added: [added], removed: [song.id], order: [added.id])]
        edited.songs = [song, second]
        precondition(edited.playlistTitle == "本機編輯" && edited.playlistSongs.map(\.id) == [added.id, second.id])
        let pending = DownloadSongMatch.downloadOrder([song, second, song], attempts: [song.videoID: Date()])
        precondition(pending.map(\.videoID) == [second.videoID, song.videoID])
        let legacy = try JSONDecoder().decode(YouTubeSyncSnapshot.self, from: Data(#"{"choice":{"id":"liked","title":"喜歡的影片"},"songs":[],"bindings":{}}"#.utf8))
        precondition(legacy.attempts == nil && legacy.choice == .liked)
        precondition(AudioRetryPolicy.delay(status: 429, retryAfter: "120") == 120)
        precondition(AudioRetryPolicy.delay(status: 503, retryAfter: "999999") == 3600)
        precondition(AudioRetryPolicy.delay(status: 429, retryAfter: "NaN") == 60)
        precondition(AudioRetryPolicy.delay(status: 200, retryAfter: "120") == nil)
        print("PASS: playlist persistence, version/artist/duration matching, lossless priority, preview and CDN rejection")
    }
}
