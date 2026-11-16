import Foundation

/// 一种歌词写法的**读法**：从"我认不认"到"读成什么"。
///
/// 每个语法一个（同族用一个、靠子格式参数分），**各自自带判据** —— 链上没有任何一处
/// 公共函数去"猜语法"。这是加一种格式只加一个文件的原因：链接口不变，新格式自己回答
/// 这两个问题。
///
/// 照 primuse 的形状（`LyricsContentParser.parse` 逐档问、`WordTimedLyricsParser.detect`
/// 自带判据）：**认一个格式要三个条件叠加** —— 形状对（`recognizedSyntax`）、
/// 读得出东西（`parse` 不返回空）、顺序不冲突（见 `LyricsTextPipeline` 的表）。
protocol LyricsTextParser {

    /// 这份文本是不是我这种写法 —— **是的话，是哪一种**。
    ///
    /// 🔴 两个问题合成一个函数：同族解析器（圆括号毫秒家族有 `lys` / `yrc` / `qrc` 三种）
    /// 靠它回答子格式；单一语法的解析器用它带的 `syntax` 常量回答。分开写就会出现
    /// "`detect` 说是我的、`syntax` 却报另一个名字"这种错位。
    ///
    /// ⚠️ 只回答"形状像不像"，**不等于"读得出来"** —— 后者由 `parse` 的返回值回答。
    /// 链是"形状对上 且 读出来非空"才真接手（照 primuse：一份逐字文档绝不能退化成
    /// 把自己的时间标记当正文）。
    static func recognizedSyntax(in text: String) -> LyricsSyntax?

    /// 读成行。**读不出东西就返回空**，链会继续问下一档。
    static func parse(_ text: String) -> [LyricsLine]
}

/// 一种写法对应一个解析器时的便利基座：只写 `detect` ＋ `syntax` 两个常量/函数即可，
/// "是哪一种"由这里合成。
///
/// 同族多语法的解析器**不要**遵循这个，自己实现 `recognizedSyntax`（它要在子格式之间分）。
protocol SingleSyntaxLyricsParser: LyricsTextParser {

    /// 我这种写法叫什么。
    static var syntax: LyricsSyntax { get }

    /// 这份文本的形状是不是我这种写法。
    static func detect(_ text: String) -> Bool
}

extension SingleSyntaxLyricsParser {
    static func recognizedSyntax(in text: String) -> LyricsSyntax? {
        detect(text) ? syntax : nil
    }
}

/// 一趟解析的结果：**读成什么**（语法）与**读出了什么**（行）。
///
/// 两样一起交出去，编辑页才能问"这份原文能不能写回"而不必再猜一遍格式
/// （以前它拿 `detect` 单独问一次，那个答案可能与 `parse` 的归宿不一致）。
struct LyricsParseOutcome {
    let syntax: LyricsSyntax
    let lines: [LyricsLine]
}

/// 探测链：**按固定顺序逐档问，谁先认谁接手**。
///
/// 这是歌词文本的**唯一入口**（`LyricsParser` 只是它的门面）。加一种格式 ＝
/// 写一个 `LyricsTextParser` ＋ 在 `parsers` 里插一行。
///
/// ## 表的顺序由"形状冲突"决定，不由偏好决定
///
/// | 位置 | 档 | 为什么排这儿 |
/// |---|---|---|
/// | 1 | TTML `ttml` | 根元素 `<tt` 唯一，不会被谁误吃；先认免得多趟 |
/// | 2 | KRC 布局 `[起,长]<相对,长,flag>字` | 行头没有冒号；字块是**尖括号 ＋ 逗号**，与字幕的冒号时间戳不冲突 |
/// | 3 | 毫秒圆括号家族（`lys` / `yrc` / `qrc`） | 行头 `[起,长]` 与 KRC 布局同形，靠**圆括号**分开；排在 KRC 布局之后，让尖括号先说话 |
/// | 4 | 字幕（`vtt` / `srt`） | 行内 `<mm:ss.ttt>` 与 ELRC 的行内字标记**形状完全一样**，必须排在 LRC 族**之前** |
/// | 5 | LRC 族 `lrc`（含纯文本兜底） | **永远认**，所以必须最后 —— 它后面再放任何档都没有机会被问到 |
///
/// ⚠️ 加档时对着这张表插，不要往末尾堆。
enum LyricsTextPipeline {

    /// 有序表 —— **最后一项必须是 `LRCLyricsParser`**（它永远认，是兜底）。
    private static let parsers: [LyricsTextParser.Type] = [
        TTMLTextParser.self,
        RelativeMillisecondsLyricsParser.self,
        ParenthesizedMillisecondsLyricsParser.self,
        SubtitleLyricsParser.self,
        LRCLyricsParser.self,
    ]

    /// 一段文本 → 行。接手的命运：命中的那一档读出来非空就用它；都读不出来 ⇒ 空。
    static func parse(_ text: String) -> [LyricsLine] {
        outcome(of: text)?.lines ?? []
    }

    /// 一段文本 → **语法 ＋ 行**。都读不出来 ⇒ `nil`。
    static func outcome(of text: String) -> LyricsParseOutcome? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for parser in parsers {
            guard let syntax = parser.recognizedSyntax(in: trimmed) else { continue }
            let lines = parser.parse(trimmed)
            if !lines.isEmpty { return LyricsParseOutcome(syntax: syntax, lines: lines) }
        }
        return nil
    }
}
