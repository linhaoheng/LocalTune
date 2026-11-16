import Foundation

/// KRC 布局 —— `[行起,行长]<字相对起,字长,flag>字…`。
///
/// 不认它的话，整份会被当成纯文本（标记原样显示、也没有时间轴）。
/// 酷狗解密出来的明文就是这种形状，取词/播放/编辑都走这里。
///
/// 规则：
/// - 行时间 = `行起`；行尾 = `行起 + 行长`（有长时）；
/// - 字时间 = `行起 + 字相对起`，字尾 = 字起 + 字长；
/// - `flag` 是背景位，暂不建模（只影响显示，不影响时间）；
/// - `[ti:]` / `[ar:]` / `[offset:]` 这类属性行进文件头，不进歌词；
///   **`[offset:]` 要真的加到轴上**（`LyricDocumentOffsetPolicy`）。
enum RelativeMillisecondsLyricsParser: SingleSyntaxLyricsParser {

    static let syntax: LyricsSyntax = .krcLayout

    private static let linePattern = try? NSRegularExpression(
        pattern: #"^\s*\[(\d+),(\d+)\]"#
    )

    private static let wordPattern = try? NSRegularExpression(
        pattern: #"<(\d+),(\d+)(?:,(\d+))?>"#
    )

    /// 文件头 `[ti:]` `[ar:]` `[offset:]` … —— 键是字母开头的。
    private static let metadataPattern = try? NSRegularExpression(
        pattern: #"^\[[A-Za-z][A-Za-z0-9_-]*:.*\]\s*$"#
    )

    /// 圆括号字块（`(起,长)` / `(起,长,0)`）—— yrc / qrc 的记号，用来把它们挡在外面。
    private static let parenthesizedWordPattern = try? NSRegularExpression(
        pattern: #"\(\d+,\d+(?:,\d+)?\)"#
    )

    /// LRC 族行头 `[mm:ss]` —— 出现它就说明这不是一份纯 KRC 布局。
    private static let lrcHeadPattern = try? NSRegularExpression(
        pattern: #"\[\d+:\d{2}"#
    )

    /// 这份文本是不是 KRC 布局 —— 两条路，**都要先有 `[起,长]` 行头**：
    ///
    /// 1. **有一行「行头 ＋ `<相对起,字长[,flag]>` 字块」** ⇒ 是。逐字档全走这条。
    /// 2. **整份没有尖括号字块、没有圆括号字块、也没有 LRC 行头** ⇒ 是（**行级** KRC 布局）。
    ///
    /// 第二条是**读写闭合**要的：我们自己的写口对"没有逐字数据的行"就写 `[起,长]正文`，
    /// 这种行必须能读回来。而它能安全地认下来，是因为 LRC 族的行头要冒号、根本吃不下它；
    /// 加上"无圆括号字块"这一条，yrc / qrc（`[起,长](…)字`）就不会被误吃。
    ///
    /// ⚠️ 第一条是**同一行**同时满足，不是"全篇各有一处"：一份文件只要有一行是
    /// "行头 ＋ 尖括号块"，整份就是这种写法（KRC 的纯间奏行可以没有字块）。
    ///
    /// 只看前 80 行 —— 照 primuse `WordTimedLyricsParser.detect` 的 `prefix(80)`：
    /// 判"是什么写法"用不着扫完整份大文件，而前 80 行足够越过文件头。
    static func detect(_ content: String) -> Bool {
        guard let linePattern, let wordPattern,
              let parenthesizedWordPattern, let lrcHeadPattern else { return false }

        var hasLineHead = false
        var hasAngleWordBlock = false
        var hasParenthesizedWordBlock = false
        var hasLRCLineHead = false

        for line in content.components(separatedBy: .newlines).prefix(80) {
            let ns = line as NSString
            guard ns.length > 0 else { continue }
            let full = NSRange(location: 0, length: ns.length)

            if linePattern.firstMatch(in: line, range: full) != nil {
                hasLineHead = true
                if wordPattern.firstMatch(in: line, range: full) != nil {
                    hasAngleWordBlock = true
                }
            }
            if parenthesizedWordPattern.firstMatch(in: line, range: full) != nil {
                hasParenthesizedWordBlock = true
            }
            if lrcHeadPattern.firstMatch(in: line, range: full) != nil {
                hasLRCLineHead = true
            }
        }

        guard hasLineHead else { return false }
        if hasAngleWordBlock { return true }
        return !hasParenthesizedWordBlock && !hasLRCLineHead
    }

    static func parse(_ content: String) -> [LyricsLine] {
        guard let linePattern, let metadataPattern else { return [] }
        var lines: [LyricsLine] = []
        var metadataLines: [String] = []
        // 文件头只在最前面认 —— 正文里出现 `[xx:yy]` 形状的东西不当头（照 LRC 族）。
        var isLeadingMetadata = true

        for raw in content.components(separatedBy: .newlines) {
            let ns = raw as NSString
            guard ns.length > 0 else { continue }
            let full = NSRange(location: 0, length: ns.length)

            if isLeadingMetadata, metadataPattern.firstMatch(in: raw, range: full) != nil {
                metadataLines.append(raw)
                continue
            }
            guard let head = linePattern.firstMatch(in: raw, range: full),
                  let startMilliseconds = Double(ns.substring(with: head.range(at: 1)))
            else { continue }
            isLeadingMetadata = false

            let durationMilliseconds = Double(ns.substring(with: head.range(at: 2))) ?? 0
            let bodyRange = NSRange(
                location: head.range.location + head.range.length,
                length: ns.length - head.range.location - head.range.length
            )
            let body = ns.substring(with: bodyRange)
            let bodyNS = body as NSString
            let marks = wordPattern?.matches(
                in: body, range: NSRange(location: 0, length: bodyNS.length)
            ) ?? []

            var syllables: [LyricSyllable] = []
            for (index, mark) in marks.enumerated() {
                let relativeStart = Double(bodyNS.substring(with: mark.range(at: 1))) ?? 0
                let duration = Double(bodyNS.substring(with: mark.range(at: 2))) ?? 0
                let textStart = mark.range.location + mark.range.length
                let textEnd = index + 1 < marks.count
                    ? marks[index + 1].range.location
                    : bodyNS.length
                guard textEnd > textStart else { continue }
                let text = bodyNS.substring(
                    with: NSRange(location: textStart, length: textEnd - textStart)
                )
                guard !text.isEmpty else { continue }

                let start = (startMilliseconds + relativeStart) / TimeUnit.millisecondsPerSecond
                // 字长是**源档给的**（KRC 每个字自带），所以结束时间是数据 ⇒ `.explicit`。
                // 零字长（`duration == 0`）也照标：那是"数据说它没时长"，不是"我们没数据"。
                syllables.append(
                    LyricSyllable(
                        text: text,
                        start: start,
                        end: start + max(0, duration) / TimeUnit.millisecondsPerSecond,
                        endTiming: .explicit
                    )
                )
            }

            let text: String
            if syllables.isEmpty {
                text = body.trimmingCharacters(in: .whitespaces)
            } else {
                var trimmed = syllables
                if var first = trimmed.first {
                    first.text = String(first.text.drop { $0 == " " || $0 == "\t" })
                    trimmed[0] = first
                }
                if var last = trimmed.last {
                    last.text = String(
                        last.text.reversed().drop { $0 == " " || $0 == "\t" }.reversed()
                    )
                    trimmed[trimmed.count - 1] = last
                }
                syllables = trimmed.filter { !$0.text.isEmpty }
                text = syllables.map(\.text).joined()
            }
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            let end = durationMilliseconds > 0
                ? (startMilliseconds + durationMilliseconds) / TimeUnit.millisecondsPerSecond
                : nil
            lines.append(
                LyricsLine(
                    timestamp: startMilliseconds / TimeUnit.millisecondsPerSecond,
                    text: text,
                    isSynchronized: true,
                    syllables: syllables.isEmpty ? nil : syllables,
                    endTimestamp: end
                )
            )
        }

        lines.sort { $0.timestamp < $1.timestamp }
        // 🔴 文件头的 `[offset:]` 要真的加到轴上 —— KRC 明文里它就在（酷狗常写 `[offset:0]`），
        // 以前这里完全忽略，同一份歌换个来源轴就差几百毫秒。行尾一起移（策略里做）。
        if let offset = LyricDocumentOffsetPolicy.offsetSeconds(in: metadataLines) {
            lines = LyricDocumentOffsetPolicy.applying(offset: offset, to: lines)
        }
        return lines
    }
}