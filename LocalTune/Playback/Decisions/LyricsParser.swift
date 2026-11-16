import Foundation

/// 「一段歌词文本 → 一行一行」的**门面**。
///
/// 这是三条入口里"内嵌文本"那一条的入口（另外两条是取词、手打），也是历史上所有调用点
/// 用的名字。它自己不含任何规则 —— 认哪一档、怎么切词，全在各自的解析器里
/// （`LyricsTextPipeline` 的有序表）。
///
/// ```
/// 文本 ──▶ LyricsTextPipeline（逐档问：形状对上 且 读得出东西）
///            ├─ TTMLTextParser                     ttml
///            ├─ RelativeMillisecondsLyricsParser   krcLayout
///            ├─ ParenthesizedMillisecondsLyrics…   lys / yrc / qrc
///            ├─ SubtitleLyricsParser               vtt / srt
///            └─ LRCLyricsParser                    lrc（含纯文本兜底）
///          ──▶ [LyricsLine]
/// ```
///
/// **纯函数**：不吃播放器、不碰界面、不知道现在唱到第几秒 —— 能在测试里不带引擎跑一遍。
///
/// ## 为什么不在这里认格式
/// 以前这里是一串 `if`：先问"像不像 KRC 布局"，不像就逐行按 LRC 读。加第三种格式时，
/// 那个 `if` 要重排，而它同时是**所有**格式的入口 —— 一处动错、每种格式都得重测。
/// 现在往 `LyricsTextPipeline` 的表里插一行就够了，判断归各自的解析器。
///
/// ## 数据从哪来
/// 内嵌歌词那**一段字符串**（侧表 `TrackLyrics.lyrics`）—— 字段可能是 LRC、增强 LRC、
/// KRC 布局、逐字歌词或纯文本，**同一列里什么都可能有**，所以只能按内容认，没有扩展名可用。
enum LyricsParser {

    /// 一段歌词文本 → 行。
    ///
    /// 没有时间戳就当纯文本（全部 `isSynchronized == false`）—— 同一次调用里自己回落，
    /// 调用方不用挑入口（primuse 分了 `parse` / `parseText` 两扇门，调错那扇会把纯文本丢掉；
    /// 我们合成一扇）。
    static func parse(_ raw: String) -> [LyricsLine] {
        LyricsTextPipeline.parse(raw)
    }

    /// 一段歌词文本 → **读成了哪种写法 ＋ 行**。
    ///
    /// 编辑页要它：能不能把原文写回、用哪个写口，全看"实际读成了什么"
    /// （`LyricsSyntax.hasWriter`），不看"看着像什么"。空文本／什么都读不出来 ⇒ `nil`。
    static func outcome(_ raw: String) -> LyricsParseOutcome? {
        LyricsTextPipeline.outcome(of: raw)
    }
}
