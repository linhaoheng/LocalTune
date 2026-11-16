import Foundation

/// **LRC 族**的读法（行级 / 字级 / 方括号逐字 / 纯文本兜底）。
///
/// 纯函数：不吃播放器、不碰界面、不知道现在唱到第几秒 —— 只把文本翻成值，
/// **能在测试里不带引擎跑一遍**。
///
/// ## 这一族里有什么
/// 行头都是 `[mm:ss]`，区别只在**每行有没有多写一层字标记**：
///
/// - **行级 LRC**：`[mm:ss]整句`（一行一个时间）；
/// - **增强 LRC（ELRC）**：行内 `<mm:ss.xx>` 逐字 → `syllables`。**行末**那个
///   后面不跟字的空块 → 数组**最后一项**（`text` 空，`LyricSyllable.isLineEnd`），
///   它就是"这一行唱到几秒"；末字的结束由它推出来；
/// - **方括号逐字**：`[00:01]词[00:02]词`（少数工具这么写逐字）；
/// - **纯文本**：一个时间戳都没有 → 全部 `isSynchronized == false`。
///
/// ⚠️ **这三档是同一套写法、不同的容量**，不是三种格式 —— 所以它们同属一个解析器
/// （照 primuse 的 `plain / lineLevel / wordLevel`：语法只有一套，能力分三档）。
/// 拆成三个解析器会让"一份 ELRC 里既有字级行也有行级行"这种常见情况无处归属。
///
/// ## 文件头往哪去
/// `[ti:]` `[ar:]` 这类行不是歌词 —— 认出来、跳过（`[offset:]` 例外：它的值要读出来
/// 加进时间轴）。**不保留**：模型里没有文档级那一格，写出也就没有它们。
///
/// ## 各项做法各归其位
/// - 行头 / 逐字正则与切词：照 primuse 的 `LyricsContentParser`
///   （`PrimuseKit/Sources/PrimuseKit/Models/LyricLine.swift`）；
/// - 增强时间戳的精度修正、`isSynchronized` 推导、`[offset:]` 夹紧：同样照 primuse。
/// - 双语配对单独一个文件：`LyricBilingualPairingPolicy.swift`。
///
/// ⚠️ **`[offset:]` 必须支持**：只认 `[mm:ss]` 行头的话，`[offset:500]` 匹配不上那个正则
/// → 那一行被整行丢掉。而内嵌 LRC 常带这个头。
enum LRCLyricsParser: SingleSyntaxLyricsParser {

    static let syntax: LyricsSyntax = .lrc

    /// 🔴 **永远认** —— 这一族是链的兜底：一句时间戳都没有的纯文本也归它（`isSynchronized`
    /// 全 `false`），再没有别的档能读。链上排在它后面的档永远不会被问到，所以它必须最后。
    static func detect(_ text: String) -> Bool { true }

    // MARK: - 正则

    /// 行头 `[mm:ss]` / `[mm:ss.xx]` / `[mm:ss:xx]` —— 分号也算小数点（照 primuse）。
    ///
    /// ⚠️ 用 `#/…/#` 扩展定界符，**不用裸 `/…/ `** —— 裸写法要 Swift 6 语言模式
    /// （或 `-enable-bare-slash-regex`），本工程是 Swift 5.9，会解析失败。
    private static let lineHeadPattern = #/\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]/#

    /// 行内逐字 `<mm:ss.xx>`。
    private static let inlineWordPattern = #/<(\d+):(\d{2})(?:[.:](\d{1,3}))?>/#

    /// 文件头 `[ti:]` `[ar:]` `[offset:]` … —— 键是字母开头的。
    private static let metadataPattern = #/^\[[A-Za-z][A-Za-z0-9_-]*:.*\]\s*$/#

    // MARK: - 入口

    /// 一段歌词文本 → 行。
    ///
    /// **没有时间戳就当纯文本**（全部 `isSynchronized == false`）—— 同一次调用里
    /// 自己回落，调用方不用挑入口（primuse 分了 `parse` / `parseText` 两扇门，
    /// 调错那扇会把纯文本丢掉；我们合成一扇）。
    static func parse(_ raw: String) -> [LyricsLine] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var lines: [LyricsLine] = []
        var metadataLines: [String] = []
        var isLeadingMetadata = true

        for rawLine in trimmed.components(separatedBy: .newlines) {
            switch parseLine(rawLine, allowMetadata: isLeadingMetadata) {
            case .metadata:
                metadataLines.append(rawLine)
            case .lyrics(let parsed):
                isLeadingMetadata = false
                lines.append(contentsOf: parsed)
            case .ignored:
                break
            }
        }

        guard !lines.isEmpty else {
            return plainLines(from: trimmed)
        }

        lines = LyricBilingualPairingPolicy.pair(lines)
        lines = orderedByTimestamp(lines)
        if let offset = LyricDocumentOffsetPolicy.offsetSeconds(in: metadataLines) {
            lines = LyricDocumentOffsetPolicy.applying(offset: offset, to: lines)
        }
        return lines
    }

    /// 一行原文的三种命运。
    private enum LineParse {
        case metadata               // 文件头（`[ti:]` 之类），只在文件头区认
        case lyrics([LyricsLine])   // 歌词行 —— 一个行头可能对多行
        case ignored                // 既不是文件头、也不是歌词行
    }

    /// 一行的解析：判文件头 → 方括号逐字 → 常规行头展开。
    ///
    /// ⚠️ `allowMetadata` ＝ 还在文件头区 —— **文件头只在最前面认**：正文里出现 `[xx:yy]`
    /// 形状的东西不当头。这个区旗由 `parse` 逐行推着走。
    private static func parseLine(_ rawLine: String, allowMetadata: Bool) -> LineParse {
        if allowMetadata, isMetadataLine(rawLine) {
            return .metadata
        }

        // 方括号逐字：一行里多个 `[mm:ss]` 之间夹着文字。
        if let squareWordLine = parseSquareWordLine(rawLine) {
            return .lyrics([squareWordLine])
        }

        let heads = rawLine.matches(of: lineHeadPattern)
        guard !heads.isEmpty, let lastHead = heads.last else {   // 不是歌词行
            return .ignored
        }
        let body = String(rawLine[lastHead.range.upperBound...])

        var lines: [LyricsLine] = []
        for head in heads {
            guard let start = parseTimestamp(min: head.1, sec: head.2, frac: head.3) else {
                continue
            }
            if let wordLine = parseWordLevelLine(
                body: body,
                lineStart: start,
                lineFractionDigits: head.3?.count
            ) {
                lines.append(wordLine)
            } else {
                let text = body.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                lines.append(LyricsLine(timestamp: start, text: text, isSynchronized: true))
            }
        }
        return .lyrics(lines)
    }

    // MARK: - 方括号逐字

    /// `[00:01]词[00:02]词` —— 行头后面**紧跟着文字**，而不是整行只有一个行头。
    private static func parseSquareWordLine(_ raw: String) -> LyricsLine? {
        guard usesSquareWordTimestamps(raw),
              let first = raw.firstMatch(of: lineHeadPattern),
              let lineStart = parseTimestamp(min: first.1, sec: first.2, frac: first.3) else {
            return nil
        }
        return parseWordLevelLine(
            body: raw,
            lineStart: lineStart,
            lineFractionDigits: first.3?.count,
            squareBrackets: true
        )
    }

    private static func usesSquareWordTimestamps(_ raw: String) -> Bool {
        let marks = raw.matches(of: lineHeadPattern)
        guard let first = marks.first,
              raw[..<first.range.lowerBound].allSatisfy({ $0.isWhitespace || $0 == "\u{FEFF}" }) else {
            return false
        }
        // 相邻两个行头之间夹着非空白文字 ⇒ 那是逐字，不是"整行复制了一遍"。
        return zip(marks, marks.dropFirst()).contains { left, right in
            !raw[left.range.upperBound..<right.range.lowerBound].allSatisfy(\.isWhitespace)
        }
    }

    // MARK: - 逐字切词

    /// 行内 `<mm:ss.xx>` → `syllables`。没有逐字标记 → `nil`（这行按行级处理）。
    private static func parseWordLevelLine(
        body: String,
        lineStart: TimeInterval,
        lineFractionDigits: Int?,
        squareBrackets: Bool = false
    ) -> LyricsLine? {
        let marks = body.matches(of: squareBrackets ? lineHeadPattern : inlineWordPattern)
        guard !marks.isEmpty else { return nil }

        var syllables: [LyricSyllable] = []
        for (index, mark) in marks.enumerated() {
            let previousStart = syllables.last?.start ?? lineStart
            guard let start = parseEnhancedWordTimestamp(
                min: mark.1,
                sec: mark.2,
                frac: mark.3,
                lineFractionDigits: lineFractionDigits,
                previousStart: previousStart
            ) else {
                continue
            }
            let textStart = mark.range.upperBound
            let textEnd = index + 1 < marks.count ? marks[index + 1].range.lowerBound : body.endIndex
            let chunk = String(body[textStart..<textEnd])

            if chunk.isEmpty || (index == marks.count - 1 && chunk.allSatisfy(\.isWhitespace)) {
                if index == marks.count - 1 {
                    // 🔴 **行尾的空块 = 这一行的结束**，留成单独一项（`text` 空）。
                    //
                    // 它不再是"某个字的结束时间"的一部分：末字的结束由下面那趟推导，
                    // 从**这一项的起点**取 —— 同一个数，只用一处表达。
                    // 编辑器靠它才有最后一格可打；写回 ELRC 时它自己就长成 `<mm:ss.mmm>`。
                    syllables.append(
                        LyricSyllable(text: "", start: start, end: start, endTiming: .explicit)
                    )
                } else if let last = syllables.last {
                    // **行内**空块（`<a>甲<b><c>乙` 中间那个 b）：它是上一个字明写的结束，
                    // 不单独占一格。
                    syllables[syllables.count - 1] = LyricSyllable(
                        text: last.text,
                        start: last.start,
                        end: max(last.end, start),
                        endTiming: .explicit
                    )
                }
                continue
            }
            // 只有起点的词：结束时间**没有**，先留 `end == start`，
            // 等下面那趟用下一个字的起点推（推不出来就保持零长）。
            syllables.append(
                LyricSyllable(text: chunk, start: start, end: start, endTiming: .inferred)
            )
        }

        guard !syllables.isEmpty else { return nil }

        // 只推**没有结束时间**的那些：明写了结束的词不许被下一个字的起点顶上去
        // —— 一旦顶了，它的 `endTiming`（`.explicit`）就在说谎。
        for index in 0..<(syllables.count - 1) where syllables[index].endTiming == .inferred {
            syllables[index].end = max(syllables[index].end, syllables[index + 1].start)
        }
        // 🔴 **末字不给兜底**：源档既没写句尾块、也推不出结束 ⇒ 让它 `end == start`（零长），
        // 下游 `KaraokeSweepPolicy.sweepProgress` 把这种窗口读成"开口即满亮"。
        // 这儿以前拍过一个 `start + 0.4` —— 那是**凭空造数**：唱多久都算 0.4 秒，
        // 而且只砸在"源档没给数据"的行末字上。数据没有就是没有，不猜。
        //
        // 有句尾块的行，末字的结束由**上面那趟推导**从那一格的起点取（标 `.inferred`）
        // —— 它只是"结束 = 下一格的起点"这条规则的结果，不是第二份数据。

        let text = syllables.map(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return LyricsLine(timestamp: lineStart, text: text, isSynchronized: true, syllables: syllables)
    }

    /// ELRC 生成器有时整行用厘秒，进位那一格却写成 `.100`。照毫秒解释会让这个词
    /// **倒退**（`.92` → `.100`），逐字高亮就跳回去。只有在标准解释会倒退、而按
    /// 本行精度解释能把顺序恢复时，才采用本行精度。
    private static func parseEnhancedWordTimestamp(
        min: Substring,
        sec: Substring,
        frac: Substring?,
        lineFractionDigits: Int?,
        previousStart: TimeInterval
    ) -> TimeInterval? {
        guard let standard = parseTimestamp(min: min, sec: sec, frac: frac),
              standard < previousStart,
              let fraction = frac,
              let lineFractionDigits,
              lineFractionDigits > 0,
              lineFractionDigits < fraction.count,
              let rawFraction = Double(fraction) else {
            return parseTimestamp(min: min, sec: sec, frac: frac)
        }

        let standardFraction = rawFraction / pow(10, Double(fraction.count))
        let linePrecisionFraction = rawFraction / pow(10, Double(lineFractionDigits))
        let adjusted = standard - standardFraction + linePrecisionFraction
        return adjusted >= previousStart ? adjusted : standard
    }

    /// `mm:ss[.fraction]` → 秒。分号/点号都当小数点，小数位按写了多少位算。
    private static func parseTimestamp(
        min: Substring,
        sec: Substring,
        frac: Substring?
    ) -> TimeInterval? {
        guard let minutes = Double(min), minutes.isFinite, minutes >= 0,
              let seconds = Double(sec), seconds.isFinite, (0..<60).contains(seconds),
              let fraction = Double(frac ?? "0"), fraction.isFinite else {
            return nil
        }
        let divisor = pow(10, Double(frac?.count ?? 2))
        let result = minutes * 60 + seconds + fraction / divisor
        // 7 天以上的一律当坏数据（跟 primuse 同一条线）。
        guard result.isFinite, result <= 7 * 24 * 3600 else { return nil }
        return result
    }

    // MARK: - 排序与纯文本

    /// 按时间排；同一时间戳的多行**保持文件里的先后**。
    ///
    /// Swift 的 `sorted` 不保证稳定，所以拿原下标当平手判据。
    private static func orderedByTimestamp(_ lines: [LyricsLine]) -> [LyricsLine] {
        lines.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.timestamp == rhs.element.timestamp {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.timestamp < rhs.element.timestamp
            }
            .map(\.element)
    }

    /// 一个时间戳都没有 → 纯文本歌词。每行 `isSynchronized == false`。
    ///
    /// 顺手把文件头（`[ti:]` 那种）滤掉 —— 否则它会当成一句歌词显示出来。
    private static func plainLines(from text: String) -> [LyricsLine] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isMetadataLine($0) }
            .map { LyricsLine(timestamp: 0, text: $0, isSynchronized: false) }
    }

    /// 文件头行（`[ti:]` `[ar:]` `[offset:]` …）。
    private static func isMetadataLine(_ raw: String) -> Bool {
        raw.firstMatch(of: metadataPattern) != nil
    }
}
