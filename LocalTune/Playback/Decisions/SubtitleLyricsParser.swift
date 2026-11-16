import Foundation

/// 字幕（WebVTT / SubRip）当歌词读。
///
/// 转录工具和视频字幕交出来的东西正好是我们模型能装下的：**一个时间窗 ＋ 一行字**，
/// 运气好还带行内逐字时间。所以 `.vtt` / `.srt` 认得出、读成行，而不是退化成
/// "满屏 `00:00:01.000 --> 00:00:02.000` 的纯文本"。
///
/// ## 🔴 为什么必须排在 LRC 族**之前**
///
/// 字幕的行内字标记 `<00:00:01.000>` 与 LRC 的 `<mm:ss.xx>` **形状完全一样**。
/// 排在后面的话，LRC 族会先接手，把 cue 时间行当成歌词正文。
///
/// ## 认它靠什么（照 primuse `SubtitleLyricsParser`）
///
/// - WebVTT：首行是 `WEBVTT`（后面必须是空白或什么都没有）；
/// - SubRip：前 60 行里有一行是"整段都是时间 ＋ `-->` ＋ 整段都是时间"。
///
/// 判据**不看** `-->` 出现没出现就完事：箭头左边必须整段都是时间戳，
/// `爱情 --> 你` 这种东西不算（正文里的箭头是标点，不是 cue）。
///
/// ## 丢什么
///
/// 样式标签（`<c.yellow>` / `<b>` / `<i>`）、`<v 名字>` 的说话人、`{\an8}` 这类
/// ASS 定位、`<rt>` 注音内容、`NOTE` / `STYLE` / `REGION` 块、`[music]` 这类噪音行。
/// 唯一保留的附属文本是"同一时间窗的第二行"—— 交给 `LyricBilingualPairingPolicy`
/// 判是不是译文（它保守：判不准就留着，我们再把它合回一行，见 `mergingWrappedRows`）。
enum SubtitleLyricsParser: LyricsTextParser {

    /// 滚动字幕会把正在滚出屏幕的上一条在同一句里重复一遍，那种 cue 短到几乎没有窗口。
    private static let fillerCueDuration: TimeInterval = 0.05

    /// 逐字尾巴没有结束时给的时长 —— 与 LRC 族那条兜底同一个数（`inferredTailDuration`）。
    private static let inferredTailDuration: TimeInterval = 0.4

    /// 转录工具拿来顶替歌词的占位词。别的括号内容都留着 —— `(Yeah)` 是真和声。
    private static let noiseTokens: Set<String> = [
        "[music]", "(music)", "[音乐]", "[音樂]",
        "[applause]", "[掌声]", "[laughter]",
    ]

    private static let musicNotes: Set<Character> = ["♪", "♫", "♬", "♩"]

    /// `[HH:]MM:SS[.,]fff`
    private static let timestampPattern = #/[ \t]*(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})[ \t]*/#

    // MARK: - 认不认

    static func recognizedSyntax(in text: String) -> LyricsSyntax? {
        let document = normalizedDocument(text)
        let lines = document.split(separator: "\n", omittingEmptySubsequences: false)
        if let first = lines.first, isWebVTTHeader(first) { return .vtt }

        var inspected = 0
        for line in lines where !line.allSatisfy(\.isWhitespace) {
            if cueTiming(in: line) != nil { return .srt }
            inspected += 1
            if inspected >= 60 { break }
        }
        return nil
    }

    // MARK: - 读

    static func parse(_ content: String) -> [LyricsLine] {
        let document = normalizedDocument(content)
        guard recognizedSyntax(in: document) != nil else { return [] }

        var cues: [Cue] = []
        for (index, block) in blocks(in: document).enumerated() {
            guard !isSkippedBlock(block, isFirstBlock: index == 0),
                  let cue = parseCue(block) else { continue }
            cues.append(cue)
        }
        guard !cues.isEmpty else { return [] }

        // 滚动字幕：极短的 cue 把上一条原样重述一遍。真歌词里的重复副歌不会被认错 ——
        // 它的 cue 窗口正常长。
        let isRollingCaptions = cues.indices.dropFirst().contains { index in
            cues[index].duration < fillerCueDuration
                && cues[index].payload.map(\.text).joined(separator: " ")
                    == cues[index - 1].payload.last?.text
        }

        var lines: [LyricsLine] = []
        for cue in cues {
            if isRollingCaptions, cue.duration < fillerCueDuration { continue }
            let payload = isRollingCaptions
                ? cue.payload.filter { !$0.marks.isEmpty || $0.text != lines.last?.text }
                : cue.payload
            guard !payload.isEmpty else { continue }

            if payload.contains(where: { !$0.marks.isEmpty }),
               let wordLevel = wordLevelLine(payload: payload, cue: cue) {
                lines.append(wordLevel)
                continue
            }
            // 同一 cue 的每一行先各自成行：是不是译文交给下面的配对策略判
            // （它只看"同时间戳 ＋ 文字家族不同"，判不准就留着，再合回一行）。
            for line in payload {
                lines.append(
                    LyricsLine(
                        timestamp: cue.start,
                        text: line.text,
                        isSynchronized: true,
                        endTimestamp: cue.end
                    )
                )
            }
        }

        lines = LyricBilingualPairingPolicy.pair(lines)
        lines = mergingWrappedRows(lines)
        return lines.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp == rhs.element.timestamp {
                return lhs.offset < rhs.offset
            }
            return lhs.element.timestamp < rhs.element.timestamp
        }.map(\.element)
    }

    // MARK: - 文档结构

    private static func normalizedDocument(_ content: String) -> String {
        var normalized = content
        if normalized.unicodeScalars.first?.value == 0xFEFF {
            normalized.removeFirst()
        }
        return normalized
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func isWebVTTHeader(_ line: Substring) -> Bool {
        guard line.hasPrefix("WEBVTT") else { return false }
        guard let next = line.dropFirst("WEBVTT".count).first else { return true }
        return next == " " || next == "\t"
    }

    /// 空行分块。⚠️ 只认**真正空**的行：滚动字幕几乎每条里都有一行只有一个空格。
    private static func blocks(in document: String) -> [[Substring]] {
        var result: [[Substring]] = []
        var current: [Substring] = []
        for line in document.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.isEmpty else {
                current.append(line)
                continue
            }
            if !current.isEmpty { result.append(current) }
            current = []
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 文件头、注释、样式块说的都不是唱什么。
    private static func isSkippedBlock(_ block: [Substring], isFirstBlock: Bool) -> Bool {
        guard let first = block.first else { return true }
        if isFirstBlock, isWebVTTHeader(first) {
            // 规范的文档在 `WEBVTT` 后面留一个空行；没留的时候这几行是"cue 编号"，
            // 不能因为当成文件头把第一条 cue 一起吞掉。
            return !block.contains { cueTiming(in: $0) != nil }
        }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        if trimmed == "STYLE" || trimmed == "REGION" { return true }
        guard trimmed.hasPrefix("NOTE") else { return false }
        guard let next = trimmed.dropFirst("NOTE".count).first else { return true }
        return next == " " || next == "\t"
    }

    private static func parseCue(_ block: [Substring]) -> Cue? {
        // 时间行之前的一切都是 cue 编号，包括 SubRip 那个序号。
        guard let timingIndex = block.firstIndex(where: { cueTiming(in: $0) != nil }),
              let timing = cueTiming(in: block[timingIndex]) else { return nil }

        var payload: [PayloadLine] = []
        for raw in block[block.index(after: timingIndex)...] {
            let cleaned = clean(raw)
            guard !isDiscardable(cleaned) else { continue }
            payload.append(cleaned)
        }
        guard !payload.isEmpty else { return nil }
        return Cue(
            start: timing.start,
            // 结束时间不晚于起点 = 根本没有窗口。
            end: timing.end > timing.start ? timing.end : nil,
            payload: payload
        )
    }

    private static func cueTiming(
        in line: Substring
    ) -> (start: TimeInterval, end: TimeInterval)? {
        guard let arrow = line.range(of: "-->"),
              let start = timestamp(from: line[..<arrow.lowerBound]) else { return nil }
        // 结束时间后面跟着 cue 设置（位置、对齐），它们是展示参数，不是歌词，
        // 但必须用空白隔开。
        let trailing = line[arrow.upperBound...].drop { $0 == " " || $0 == "\t" }
        guard let end = timestamp(from: trailing.prefix { $0 != " " && $0 != "\t" }) else {
            return nil
        }
        return (start, end)
    }

    private static func timestamp(from field: Substring) -> TimeInterval? {
        guard let match = field.wholeMatch(of: timestampPattern),
              let minutes = Int(match.2),
              let seconds = Int(match.3),
              let fraction = Int(match.4) else { return nil }
        let hours = match.1.flatMap { Int($0) } ?? 0
        guard hours <= 100_000 else { return nil }
        // 1 位小数是十位、2 位是百位。毫秒先加再换算 —— 窗口边界落在整毫秒上，
        // 不是二进制小数的尾巴。
        let scale: Int
        switch match.4.count {
        case 1: scale = 100
        case 2: scale = 10
        default: scale = 1
        }
        let total = ((hours * 60 + minutes) * 60 + seconds) * 1_000 + fraction * scale
        return TimeInterval(total) / 1_000
    }

    // MARK: - 一行的清理

    /// 一个字一个字地剥 cue 标记。
    ///
    /// 不能用一串 `replacingOccurrences`：`<rt>` 要**连内容一起丢**，别的标签只丢标签本身，
    /// 而行内时间戳在文字被改写之后还得指着它原本开头的那个字。
    private static func clean(_ raw: Substring) -> PayloadLine {
        var characters: [Character] = []
        var marks: [InlineMark] = []

        func append(_ text: String) {
            for character in text {
                guard character.isWhitespace else {
                    characters.append(character)
                    continue
                }
                // 连续空白并成一个；开头的空白直接不落。
                if let last = characters.last, last != " " { characters.append(" ") }
            }
        }

        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            switch character {
            case "<":
                guard let close = raw[index...].firstIndex(of: ">") else {
                    // 没配对的 `<` 是正文，不是坏标签。
                    append(String(character))
                    index = raw.index(after: index)
                    continue
                }
                let body = raw[raw.index(after: index)..<close]
                index = raw.index(after: close)
                if let start = timestamp(from: body) {
                    marks.append(InlineMark(offset: characters.count, start: start))
                } else if isRubyAnnotationTag(body) {
                    // `<rt>` 是注音拼写，不是唱出来的字。
                    index = skippingRubyAnnotation(in: raw, from: index)
                }
                // 其余标签（`<v 名字>` / `<c.yellow>` / `<b>` / 闭合标签）只丢标记，
                // 文字留着。
            case "{":
                let bodyStart = raw.index(after: index)
                // `{\an8}` 之类是 ASS 定位；开括号后面不是反斜杠的就是正文标点。
                guard bodyStart < raw.endIndex, raw[bodyStart] == "\\",
                      let close = raw[bodyStart...].firstIndex(of: "}") else {
                    append(String(character))
                    index = bodyStart
                    continue
                }
                index = raw.index(after: close)
            case "&":
                let entity = decodedEntity(in: raw, from: index)
                append(entity.text)
                index = entity.end
            default:
                append(String(character))
                index = raw.index(after: index)
            }
        }

        while characters.last == " " { characters.removeLast() }
        var leading = characters.startIndex
        while leading < characters.endIndex, isTrimmableEdge(characters[leading]) {
            leading += 1
        }
        var trailing = characters.endIndex
        while trailing > leading, isTrimmableEdge(characters[trailing - 1]) {
            trailing -= 1
        }
        let trimmed = Array(characters[leading..<trailing])
        return PayloadLine(
            characters: trimmed,
            marks: marks.map {
                InlineMark(
                    offset: min(max(0, $0.offset - leading), trimmed.count),
                    start: $0.start
                )
            }
        )
    }

    /// 装饰用的音符符号和它两边的空白是框，不是歌词。
    private static func isTrimmableEdge(_ character: Character) -> Bool {
        character == " " || musicNotes.contains(character)
    }

    private static func isDiscardable(_ line: PayloadLine) -> Bool {
        let text = line.text
        return text.isEmpty || noiseTokens.contains(text.lowercased())
    }

    private static func isRubyAnnotationTag(_ body: Substring) -> Bool {
        body.prefix { !$0.isWhitespace }.lowercased() == "rt"
    }

    private static func skippingRubyAnnotation(
        in raw: Substring,
        from index: Substring.Index
    ) -> Substring.Index {
        raw.range(of: "</rt>", options: .caseInsensitive, range: index..<raw.endIndex)?
            .upperBound ?? raw.endIndex
    }

    private static func decodedEntity(
        in raw: Substring,
        from index: Substring.Index
    ) -> (text: String, end: Substring.Index) {
        let bodyStart = raw.index(after: index)
        let literal = (String(raw[index]), bodyStart)
        guard let close = raw[bodyStart...].prefix(12).firstIndex(of: ";") else { return literal }
        let name = raw[bodyStart..<close]
        let end = raw.index(after: close)

        switch name.lowercased() {
        case "amp": return ("&", end)
        case "lt": return ("<", end)
        case "gt": return (">", end)
        case "quot": return ("\"", end)
        case "apos": return ("'", end)
        case "nbsp": return (" ", end)
        case "lrm", "rlm":
            // 方向标记是看不见的排版字符；留着会让两条一模一样的字幕比成"不同"。
            return ("", end)
        default:
            break
        }

        guard name.hasPrefix("#") else { return literal }
        let digits = name.dropFirst()
        let value = digits.first == "x" || digits.first == "X"
            ? UInt32(digits.dropFirst(), radix: 16)
            : UInt32(digits, radix: 10)
        guard let value, let scalar = Unicode.Scalar(value) else { return literal }
        return (String(Character(scalar)), end)
    }

    // MARK: - 成行

    /// 软换行的两行仍然是**一句**，所以字标记要跨物理换行接着算。
    private static func wordLevelLine(payload: [PayloadLine], cue: Cue) -> LyricsLine? {
        var characters: [Character] = []
        var marks: [InlineMark] = []
        for line in payload {
            if !characters.isEmpty { characters.append(" ") }
            let offset = characters.count
            marks.append(contentsOf: line.marks.map {
                InlineMark(offset: $0.offset + offset, start: $0.start)
            })
            characters.append(contentsOf: line.characters)
        }

        // 时间戳往回走、或跑到 cue 窗口外面的，说明这是另一份文档的记号 ——
        // 那就老实读成行级。
        guard let first = marks.first, let last = marks.last,
              first.start >= cue.start,
              last.start <= (cue.end ?? .greatestFiniteMagnitude),
              zip(marks, marks.dropFirst()).allSatisfy({ $0.start <= $1.start }) else {
            return nil
        }

        var syllables: [LyricSyllable] = []
        var segmentStart = 0
        var segmentTime = cue.start
        for mark in marks {
            let text = String(characters[segmentStart..<mark.offset])
            if !text.isEmpty {
                syllables.append(
                    LyricSyllable(
                        text: text,
                        start: segmentTime,
                        end: mark.start,
                        endTiming: .inferred
                    )
                )
            }
            segmentStart = mark.offset
            segmentTime = mark.start
        }

        let tail = String(characters[segmentStart...])
        if !tail.isEmpty {
            syllables.append(
                LyricSyllable(
                    text: tail,
                    start: segmentTime,
                    end: cue.end ?? (segmentTime + inferredTailDuration),
                    endTiming: cue.end == nil ? .inferred : .explicit
                )
            )
        } else if var closing = syllables.last, let end = cue.end, end > closing.start {
            closing.end = end
            closing.endTiming = .explicit
            syllables[syllables.count - 1] = closing
        }

        guard !syllables.isEmpty else { return nil }
        let text = syllables.map(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return LyricsLine(
            timestamp: cue.start,
            text: text,
            isSynchronized: true,
            syllables: syllables,
            endTimestamp: cue.end
        )
    }

    /// 配对策略没吃下的那些行，其实是**一句被软换行折断** —— 合回一行。
    ///
    /// 判据：相邻两行时间窗**完全一样**。同一 cue 的每一行本来就共享一个窗口，
    /// 而不同 cue 的窗口不会一模一样（真撞上了，合起来也只是显示成一行）。
    private static func mergingWrappedRows(_ lines: [LyricsLine]) -> [LyricsLine] {
        var result: [LyricsLine] = []
        for line in lines {
            if let previous = result.last,
               previous.manualTranslation == nil,
               line.manualTranslation == nil,
               previous.endTimestamp == line.endTimestamp,
               abs(previous.timestamp - line.timestamp) < 0.002 {
                var merged = previous
                merged.text = previous.text + " " + line.text
                result[result.count - 1] = merged
                continue
            }
            result.append(line)
        }
        return result
    }

    // MARK: - 内部类型

    /// 行内字标记：只留"在清理后的文本里第几个字"，因为剥标签、解实体、折空白
    /// 都会把它的位置挪走。
    private struct InlineMark {
        let offset: Int
        let start: TimeInterval
    }

    private struct PayloadLine {
        let characters: [Character]
        let marks: [InlineMark]

        var text: String { String(characters) }
    }

    private struct Cue {
        let start: TimeInterval
        /// 文档没给可用窗口时是 `nil`。
        let end: TimeInterval?
        let payload: [PayloadLine]

        var duration: TimeInterval { max(0, (end ?? start) - start) }
    }
}
