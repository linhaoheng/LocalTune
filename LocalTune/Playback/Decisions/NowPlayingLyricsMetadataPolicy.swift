import Foundation

/// 锁屏 / 控制中心标题槽要写什么——纯函数，不碰 `MPNowPlayingInfoCenter`。
///
/// 做法照 primuse `NowPlayingLyricsMetadataPolicy`（手机那条）。**不跟**这几种写法：
/// 空格删光、艺人空还拼 `歌名 - `、seek 回第一句之前还挂着上一句。
/// 规格：`docs/设计/锁屏-标题当前行.md`。
enum NowPlayingLyricsMetadataPolicy {

    /// 锁屏上要显示的标题和艺人。已经是给系统的文案，不是库里的歌名再改一回。
    struct Presentation: Equatable {
        var title: String
        var artist: String
    }

    /// 能驱动锁屏换行的句子：同步、时间有限、去空白后还有字。
    ///
    /// 只看歌词文档本身，跟播到哪儿无关 —— 换歌时滤一次即可。
    static func synchronizedLines(_ lyrics: [LyricsLine]) -> [LyricsLine] {
        lyrics.filter {
            $0.isSynchronized
                && $0.timestamp.isFinite
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func presentation(
        songTitle: String,
        artist: String,
        lyrics: [LyricsLine],
        playbackTime: TimeInterval
    ) -> Presentation {
        presentation(
            songTitle: songTitle,
            artist: artist,
            synchronizedLyrics: synchronizedLines(lyrics),
            playbackTime: playbackTime
        )
    }

    /// 调用方已经拿过 `synchronizedLines` 时走这条，避免每拍再滤一遍。
    static func presentation(
        songTitle: String,
        artist: String,
        synchronizedLyrics: [LyricsLine],
        playbackTime: TimeInterval
    ) -> Presentation {
        let title = songTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = Presentation(title: title, artist: trimmedArtist)

        guard playbackTime.isFinite, playbackTime >= 0 else { return canonical }
        guard let firstLine = synchronizedLyrics.first,
              playbackTime >= firstLine.timestamp,
              let activeIndex = LyricsPlaybackPolicy.activeLineIndex(
                in: synchronizedLyrics,
                at: playbackTime
              ) else { return canonical }

        let line = synchronizedLyrics[activeIndex]
        let secondary = [title, trimmedArtist].filter { !$0.isEmpty }.joined(separator: " · ")
        return Presentation(
            title: line.text.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: secondary
        )
    }
}
