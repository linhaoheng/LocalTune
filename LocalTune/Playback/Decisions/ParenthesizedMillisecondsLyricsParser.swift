import Foundation

/// 毫秒级、**圆括号**字块的三种逐字歌词：`lys` / `yrc` / `qrc`。
///
/// 三者的共同点：时间全是整数毫秒、字块写在圆括号里、行头没有 `mm:ss` 冒号。
/// 差别只在**字块在字前还是字后**、**行头是什么**：
///
/// ```
/// lys  [属性数字]字(字起,字长)…            属性数字编码对唱声部与和声组
/// yrc  [行起,行长](字起,字长,0)字…          字块在字**前面**
/// qrc  [行起,行长]字(字起,字长)…            字块在字**后面**，常在 XML 外壳里
/// ```
///
/// 同族一个解析器、子格式靠参数分（照 primuse `WordTimedLyricsParser`）——
/// 拆成三个文件会把同一套切词逻辑抄三遍。
///
/// ## 🔴 为什么要认它们，而不是让它们落给 LRC 族
///
/// 它们的行头 `[起,长]` 与 KRC 布局同形；KRC 布局的 `detect` 现在要求**尖括号**字块，
/// 所以它们在这里落选之后会掉到 LRC 族 —— 而 LRC 族的行头要冒号，也读不出来，
/// 最终整份退化成"带着 `[1000,2000](…)` 标记的纯文本"。所以必须在链上给它们一档。
///
/// ## 这一档丢什么（与 `歌词子系统设计.md` §3.6 同口径）
///
/// - **和声行**（整行被圆括号包住那种）：认出来、**丢掉**，不进正文 —— 模型没有"和声"
///   这一格，留着就会以普通行的样子重复唱一遍（primuse 把它挂到上一条的 `background`，
///   我们没那格，按定案一律丢）。
/// - **对唱声部**（lys 的属性数字）：同样不建模，不影响时间。
/// - **文件头**：读 `[offset:]` 进时间轴，其余不保留。
///
/// 所有时间都是**源档给的整数毫秒**，求和之后才换算成秒 —— 免得加出二进制小数尾巴
/// （照 primuse `makeLine` 的写法）。
enum ParenthesizedMillisecondsLyricsParser: LyricsTextParser {

    /// 三种子格式。
    private enum SubFormat {
        case lys
        case yrc
        case qrc
    }

    private static let openingParentheses: Set<Character> = ["(", "（"]
    private static let closingParentheses: Set<Character> = [")", "）"]

    // MARK: - 认不认

    /// 前 80 行里数三种子格式各有多少行"行头 ＋ 字块都齐"，谁多算谁。
    ///
    /// 照 primuse `WordTimedLyricsParser.detect`：计数而不是"见到一个就算"，
    /// 是为了让一份夹着几行杂质的文档仍能归到对的那一档。
    static func recognizedSyntax(in text: String) -> LyricsSyntax? {
        guard let format = detectFormat(in: text) else { return nil }
        switch format {
        case .lys: return .lys
        case .yrc: return .yrc
        case .qrc: return .qrc
        }
    }

    private static func detectFormat(in content: String) -> SubFormat? {
        let body = unwrappingQRCDocument(content) ?? content
        var lysLines = 0
        var yrcLines = 0
        var qrcLines = 0

        for raw in body.components(separatedBy: .newlines).prefix(80) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !isDocumentMetadata(line) else { continue }
            if lysProperty(in: line) != nil, !markers(in: line, fieldCount: 2).isEmpty {
                lysLines += 1
            } else if lineHeader(in: line) != nil {
                if !markers(in: line, fieldCount: 3).isEmpty {
                    yrcLines += 1
                } else if !markers(in: line, fieldCount: 2).isEmpty {
                    qrcLines += 1
                }
            }
        }

        let best = max(lysLines, yrcLines, qrcLines)
        guard best > 0 else { return nil }
        if best == lysLines { return .lys }
        if best == yrcLines { return .yrc }
        return .qrc
    }

    // MARK: - 读

    static func parse(_ content: String) -> [LyricsLine] {
        guard let format = detectFormat(in: content) else { return [] }
        let body = unwrappingQRCDocument(content) ?? content
        var metadataLines: [String] = []
        var lines: [LyricsLine] = []

        for raw in body.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if isDocumentMetadata(trimmed) {
                if trimmed.hasPrefix("[") { metadataLines.append(trimmed) }
                continue
            }
            guard var parsed = parseLine(trimmed, as: format) else { continue }
            guard let line = resolveAndMake(&parsed) else { continue }
            lines.append(line)
        }

        guard !lines.isEmpty else { return [] }
        if let offset = LyricDocumentOffsetPolicy.offsetSeconds(in: metadataLines) {
            lines = LyricDocumentOffsetPolicy.applying(offset: offset, to: lines)
        }
        return lines
    }

    // MARK: - 行

    private struct ParsedWord {
        var text: String
        let start: Int
        let duration: Int
    }

    private struct ParsedLine {
        var words: [ParsedWord]
        let start: Int?
        let duration: Int?
    }

    private static func parseLine(_ line: String, as format: SubFormat) -> ParsedLine? {
        switch format {
        case .lys: return parseLYSLine(line)
        case .qrc: return parseQRCLine(line)
        case .yrc: return parseYRCLine(line)
        }
    }

    private static func parseLYSLine(_ line: String) -> ParsedLine? {
        guard let property = lysProperty(in: line) else { return nil }
        let words = trailingTimedWords(in: String(line[property.contentStart...]))
        guard !words.isEmpty else { return nil }
        return ParsedLine(words: words, start: words.first?.start, duration: nil)
    }

    private static func parseQRCLine(_ line: String) -> ParsedLine? {
        guard let header = lineHeader(in: line) else { return nil }
        let words = trailingTimedWords(in: String(line[header.contentStart...]))
        guard !words.isEmpty else { return nil }
        return ParsedLine(words: words, start: header.start, duration: header.duration)
    }

    private static func parseYRCLine(_ line: String) -> ParsedLine? {
        guard let header = lineHeader(in: line) else { return nil }
        let words = leadingTimedWords(in: String(line[header.contentStart...]))
        guard !words.isEmpty else { return nil }
        return ParsedLine(words: words, start: header.start, duration: header.duration)
    }

    /// 和声行整行被圆括号包住 —— 认出来就**丢掉整行**（见类型注释）。
    private static func resolveAndMake(_ parsed: inout ParsedLine) -> LyricsLine? {
        guard let firstIndex = parsed.words.firstIndex(where: { !$0.text.isEmpty }),
              let lastIndex = parsed.words.lastIndex(where: { !$0.text.isEmpty }) else {
            return nil
        }
        let opensWithParenthesis = parsed.words[firstIndex].text
            .trimmingCharacters(in: .whitespaces)
            .first
            .map(openingParentheses.contains) ?? false
        let closesWithParenthesis = parsed.words[lastIndex].text
            .trimmingCharacters(in: .whitespaces)
            .last
            .map(closingParentheses.contains) ?? false
        guard !(opensWithParenthesis && closesWithParenthesis) else { return nil }
        return makeLine(parsed)
    }

    /// lys / qrc 的字块在字**后面**：一个字 = 从上一块结束到这一块开始。
    private static func trailingTimedWords(in content: String) -> [ParsedWord] {
        var words: [ParsedWord] = []
        var cursor = content.startIndex
        var textStart = content.startIndex

        while let marker = nextMarker(in: content, from: cursor, fieldCount: 2) {
            words.append(ParsedWord(
                text: String(content[textStart..<marker.start]),
                start: marker.fields[0],
                duration: marker.fields[1]
            ))
            cursor = marker.end
            textStart = marker.end
        }
        return words
    }

    /// yrc 的字块在字**前面**：一个字 = 从这个块结束到下一个块开始。
    private static func leadingTimedWords(in content: String) -> [ParsedWord] {
        var found: [(start: Int, duration: Int, textStart: String.Index)] = []
        var cursor = content.startIndex
        var textEnds: [String.Index] = []

        while let marker = nextMarker(in: content, from: cursor, fieldCount: 3) {
            if !found.isEmpty { textEnds.append(marker.start) }
            found.append((marker.fields[0], marker.fields[1], marker.end))
            cursor = marker.end
        }
        guard !found.isEmpty else { return [] }
        textEnds.append(content.endIndex)

        return zip(found, textEnds).map { marker, textEnd in
            ParsedWord(
                text: String(content[marker.textStart..<textEnd]),
                start: marker.start,
                duration: marker.duration
            )
        }
    }

    private static func makeLine(_ parsed: ParsedLine) -> LyricsLine? {
        let syllables = parsed.words.compactMap { word -> LyricSyllable? in
            guard !word.text.isEmpty else { return nil }
            // 毫秒先加再换算：结束时间落在整毫秒上，不是二进制小数的尾巴。
            return LyricSyllable(
                text: word.text,
                start: seconds(word.start),
                end: seconds(word.start + max(0, word.duration)),
                endTiming: .explicit
            )
        }
        guard !syllables.isEmpty else { return nil }

        let text = syllables.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let timestamp = parsed.start.map(seconds) ?? syllables[0].start
        var headerEnd: TimeInterval?
        if let start = parsed.start, let duration = parsed.duration {
            headerEnd = seconds(start + duration)
        }
        return LyricsLine(
            timestamp: timestamp,
            text: text,
            isSynchronized: true,
            syllables: syllables,
            endTimestamp: max(headerEnd ?? 0, syllables[syllables.count - 1].end)
        )
    }

    // MARK: - 记号

    private struct Marker {
        let fields: [Int]
        let start: String.Index
        let end: String.Index
    }

    /// 找下一个 `(a,b)` / `(a,b,c)`。
    ///
    /// 歌词正文本来就可能有圆括号，所以"像个括号"不算数：**字段数正好**
    /// 且每个字段都是整数才算记号（照 primuse `nextMarker`）。
    private static func nextMarker(
        in text: String,
        from index: String.Index,
        fieldCount: Int
    ) -> Marker? {
        var cursor = index
        while let open = text[cursor...].firstIndex(where: { openingParentheses.contains($0) }) {
            // 全角括号只用来识别"和声行"，不认作时间记号 —— 时间记号只写半角。
            if text[open] == "(",
               let close = text[open...].firstIndex(of: ")") {
                let fields = text[text.index(after: open)..<close]
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map { Int($0.trimmingCharacters(in: .whitespaces)) }
                if fields.count == fieldCount, fields.allSatisfy({ $0 != nil }) {
                    return Marker(
                        fields: fields.compactMap { $0 },
                        start: open,
                        end: text.index(after: close)
                    )
                }
            }
            guard open < text.endIndex else { return nil }
            cursor = text.index(after: open)
        }
        return nil
    }

    private static func markers(in line: String, fieldCount: Int) -> [Marker] {
        var result: [Marker] = []
        var cursor = line.startIndex
        while let marker = nextMarker(in: line, from: cursor, fieldCount: fieldCount) {
            result.append(marker)
            cursor = marker.end
        }
        return result
    }

    private struct LYSProperty {
        let contentStart: String.Index
    }

    /// lys 行头：`[单个数字]`，取值 0…8。
    ///
    /// 那个数字编码对唱声部与和声组（0-2 未标注、3-5 主唱、6-8 和声），我们不建模 ——
    /// 只要确认"这是 lys 行头"。⚠️ 只有一位数字：`[1000,2000]`（yrc/qrc 行头）不会被误认。
    private static func lysProperty(in line: String) -> LYSProperty? {
        guard line.hasPrefix("["),
              let close = line.firstIndex(of: "]") else { return nil }
        let digits = line[line.index(after: line.startIndex)..<close]
        guard digits.count == 1, let property = Int(digits), (0...8).contains(property) else {
            return nil
        }
        return LYSProperty(contentStart: line.index(after: close))
    }

    private struct LineHeader {
        let start: Int
        let duration: Int
        let contentStart: String.Index
    }

    /// yrc / qrc 行头：`[行起,行长]`，两个非负整数。
    private static func lineHeader(in line: String) -> LineHeader? {
        guard line.hasPrefix("["),
              let close = line.firstIndex(of: "]") else { return nil }
        let fields = line[line.index(after: line.startIndex)..<close]
            .split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let start = Int(fields[0].trimmingCharacters(in: .whitespaces)),
              let duration = Int(fields[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, duration >= 0 else { return nil }
        return LineHeader(
            start: start,
            duration: duration,
            contentStart: line.index(after: close)
        )
    }

    /// 文件头：`[key:…]`（键全是字母）或 NetEase 放在文件顶的 JSON 行。
    ///
    /// ⚠️ lys 的 `[3]` 与 yrc/qrc 的 `[1000,2000]` 都**没有冒号**，不会被当文件头。
    private static func isDocumentMetadata(_ line: String) -> Bool {
        if line.hasPrefix("{") { return true }
        guard line.hasPrefix("["), line.hasSuffix("]"),
              let separator = line.firstIndex(of: ":") else { return false }
        let key = line[line.index(after: line.startIndex)..<separator]
        return !key.isEmpty && key.allSatisfy { $0.isLetter }
    }

    /// qrc 有时整份装在一个 XML 外壳里：`<Lyric_1 LyricContent="[1000,2000]…"/>`。
    /// 属性值是转义过的，取出来要还原实体（照 primuse `unwrappingQRCDocument`）。
    private static func unwrappingQRCDocument(_ content: String) -> String? {
        guard content.range(of: "LyricContent", options: .caseInsensitive) != nil,
              let attribute = content.range(of: "LyricContent=\"", options: .caseInsensitive),
              let close = content[attribute.upperBound...].firstIndex(of: "\"") else {
            return nil
        }
        let escaped = content[attribute.upperBound..<close]
        return escaped
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&#13;", with: "")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func seconds(_ milliseconds: Int) -> TimeInterval {
        TimeInterval(milliseconds) / TimeUnit.millisecondsPerSecond
    }
}
