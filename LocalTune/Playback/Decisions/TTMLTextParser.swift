import Foundation

/// TTML 的**只读版**：认得出、读得出时间，但译文／注音／和声一律**丢掉**。
///
/// 照 `歌词子系统设计.md` §3.6 的定案：
///
/// - **要认**：不认的话整份会落到 LRC 族，标签 `<p begin="…">` 会被当成正文显示出来；
/// - **要读**：段落（`<p>`）与音节（`<span begin>`）的时间进时间轴，能跟拍、能扫光；
/// - **丢**：`ttm:role="x-translation"`（译文）、`x-roman`（注音）、`x-bg`（和声）——
///   模型没有这三格，留着就会把译文拼进正文、把和声当正行唱一遍；
/// - **不写回**：TTML 编辑另议（`编辑歌词页-TTML与结构化编辑.md`），编辑页对它只读。
///
/// ```
/// <tt><body><div>
///   <p begin="12.345" end="15.000" ttm:agent="v1">
///     <span begin="12.345" end="12.700">你</span>
///     <span begin="12.700" end="13.100">好</span>
///     <span ttm:role="x-bg" begin="13.100" end="14.000">（和声）</span>
///   </p>
/// </div></body></tt>
/// ```
///
/// 时间写法照 primuse 的 `parseTimestamp` 全收：`HH:MM:SS.fff`（Apple Music 常用）、
/// `1.5s` / `1500ms` / `2m` / `1h` 这类 TTML 允许的偏移写法，逗号小数也认。
enum TTMLTextParser: SingleSyntaxLyricsParser {

    static let syntax: LyricsSyntax = .ttml

    /// 根元素 `<tt`（可带命名空间前缀）。
    ///
    /// ⚠️ 只判**形状**：读不出来（畸形 XML）时 `parse` 返回空，链继续问下一档 ——
    /// 所以这里宽松一点没有代价。
    static func detect(_ text: String) -> Bool {
        text.range(
            of: #"<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?tt(?:\s|>)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func parse(_ text: String) -> [LyricsLine] {
        guard detect(text),
              // 外部实体与 DTD 一律不碰（照 primuse：带 DOCTYPE/ENTITY 的直接放弃，
              // 免得解析器去读文件或展开实体）。
              text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil,
              let data = text.data(using: .utf8) else { return [] }

        let delegate = TTMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse(), delegate.sawRoot else { return [] }
        return delegate.finishedLines.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - 时间

    /// TTML 的时间属性 → 秒。
    ///
    /// 三种写法都要认：带单位的（`1.5s` / `1500ms` / `2m` / `1h`）、`HH:MM:SS.fff`
    /// （Apple Music 常用）、`MM:SS.fff`。逗号当小数点（TTML 允许）。
    /// 7 天以上当坏数据（与别处同一条线）。
    static func seconds(from rawValue: String) -> TimeInterval? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        let units: [(suffix: String, multiplier: Double)] = [
            ("ms", 0.001),
            ("h", 3_600),
            ("m", 60),
            ("s", 1),
        ]
        for unit in units where value.hasSuffix(unit.suffix) {
            guard let amount = Double(value.dropLast(unit.suffix.count)) else { return nil }
            return validated(amount * unit.multiplier)
        }

        let components = value
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count),
              let last = components.last.flatMap({ Double($0) }),
              last >= 0 else { return nil }

        let result: Double
        switch components.count {
        case 1:
            result = last
        case 2:
            guard let minutes = Double(components[0]), minutes >= 0, last < 60 else { return nil }
            result = minutes * 60 + last
        case 3:
            guard let hours = Double(components[0]), hours >= 0,
                  let minutes = Double(components[1]), (0..<60).contains(minutes),
                  last < 60 else { return nil }
            result = hours * 3_600 + minutes * 60 + last
        default:
            return nil
        }
        return validated(result)
    }

    private static func validated(_ value: TimeInterval) -> TimeInterval? {
        guard value.isFinite, value >= 0, value <= 7 * 24 * 3_600 else { return nil }
        return value
    }
}

// MARK: - XML

/// 一次解析的现场。`XMLParser` 是回调式的，状态只能挂在 delegate 上。
private final class TTMLDelegate: NSObject, XMLParserDelegate {

    /// 段落里按**出现顺序**摆的碎片：直接文字、或一个已经定格的字。
    private enum Fragment {
        case text(String)
        case syllable(LyricSyllable)
    }

    /// 一个还开着的 `<span>`。
    private struct OpenSpan {
        let role: String?
        let begin: TimeInterval?
        let end: TimeInterval?
        var text: String
    }

    /// 这三个角色是**展示用**的附属文本，不进正文（§3.6 定案）。
    private static let droppedRoles: Set<String> = [
        "x-bg", "x-translation", "x-roman", "x-romaji", "x-romanization",
    ]

    private(set) var sawRoot = false
    private(set) var finishedLines: [LyricsLine] = []

    private var insideParagraph = false
    private var paragraphBegin: TimeInterval?
    private var paragraphEnd: TimeInterval?
    private var fragments: [Fragment] = []
    private var spans: [OpenSpan] = []

    // MARK: 元素

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(elementName) {
        case "tt":
            sawRoot = true
        case "p":
            insideParagraph = true
            paragraphBegin = time("begin", in: attributeDict)
            paragraphEnd = time("end", in: attributeDict)
                ?? durationEnd("dur", begin: paragraphBegin, in: attributeDict)
            fragments = []
            spans = []
        case "span" where insideParagraph:
            spans.append(
                OpenSpan(
                    role: role(in: attributeDict),
                    begin: time("begin", in: attributeDict),
                    end: time("end", in: attributeDict),
                    text: ""
                )
            )
        case "br" where insideParagraph:
            appendText(" ")
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName) {
        case "span" where insideParagraph:
            closeSpan()
        case "p" where insideParagraph:
            closeParagraph()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideParagraph else { return }
        guard !isDropping else { return }
        if spans.isEmpty {
            appendText(flattened(string))
        } else {
            spans[spans.count - 1].text += string
        }
    }

    // MARK: 段落收尾

    private func closeSpan() {
        guard let span = spans.popLast() else { return }
        guard let role = span.role, Self.droppedRoles.contains(role) else {
            commitSpan(span)
            return
        }
        // 被丢的角色：整段文字不进正文。
    }

    private func commitSpan(_ span: OpenSpan) {
        let text = flattened(span.text)
        guard !text.isEmpty else { return }
        guard let begin = span.begin else {
            // 没有起点 ⇒ 不是逐字，只是一个文字片段。
            appendText(text)
            return
        }
        let end = span.end ?? begin
        // 有起点就是源档给的时间 ⇒ `.explicit`（哪怕是零长，也是"源档说它没时长"）。
        fragments.append(
            .syllable(
                LyricSyllable(text: text, start: begin, end: max(begin, end), endTiming: .explicit)
            )
        )
    }

    private func closeParagraph() {
        insideParagraph = false
        defer {
            fragments = []
            paragraphBegin = nil
            paragraphEnd = nil
            spans = []
        }

        let text = fragments
            .map { fragment -> String in
                switch fragment {
                case .text(let value): return value
                case .syllable(let syllable): return syllable.text
                }
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let syllables = fragments.compactMap { fragment -> LyricSyllable? in
            if case .syllable(let syllable) = fragment { return syllable }
            return nil
        }
        let timestamp = paragraphBegin ?? syllables.first?.start ?? 0
        finishedLines.append(
            LyricsLine(
                timestamp: timestamp,
                text: text,
                isSynchronized: paragraphBegin != nil || !syllables.isEmpty,
                syllables: syllables.isEmpty ? nil : syllables,
                endTimestamp: paragraphEnd
            )
        )
    }

    // MARK: 小工具

    /// 当前是不是在"要丢掉的角色"里 —— 嵌套的话，任一层是就丢。
    private var isDropping: Bool {
        spans.contains { span in
            guard let role = span.role else { return false }
            return Self.droppedRoles.contains(role)
        }
    }

    private func appendText(_ string: String) {
        guard !string.isEmpty else { return }
        if case .text(let existing)? = fragments.last {
            fragments[fragments.count - 1] = .text(existing + string)
        } else {
            fragments.append(.text(string))
        }
    }

    /// 空白折叠成单空格，开头的空白直接不落（照 primuse 的 `append`）。
    ///
    /// 🔴 TTML 的作者排版会把每行缩进、标签之间的换行都写进文字里 —— 那些不是歌词内容。
    /// 不折叠的话一行会变成 `"你\n好"`，界面上真的换行。
    private func flattened(_ text: String) -> String {
        var result = ""
        for character in text {
            guard character.isWhitespace else {
                result.append(character)
                continue
            }
            if !result.isEmpty, result.last != " " { result.append(" ") }
        }
        return result
    }

    /// `ttm:role` / `role` —— 命名空间处理开/关时键名不同，两种都认。
    private func role(in attributes: [String: String]) -> String? {
        guard let value = attribute("role", in: attributes) else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func time(_ name: String, in attributes: [String: String]) -> TimeInterval? {
        attribute(name, in: attributes).flatMap(TTMLTextParser.seconds(from:))
    }

    /// `dur="1.5s"` 这种：结束 = 起点 ＋ 时长。
    private func durationEnd(
        _ name: String,
        begin: TimeInterval?,
        in attributes: [String: String]
    ) -> TimeInterval? {
        guard let begin,
              let duration = attribute(name, in: attributes)
                  .flatMap(TTMLTextParser.seconds(from:)) else { return nil }
        return begin + duration
    }

    /// 属性名按**本地名**匹配：`ttm:role` 与 `role` 都要认（命名空间处理开关不同）。
    private func attribute(_ name: String, in attributes: [String: String]) -> String? {
        attributes.first { localName($0.key) == name.lowercased() }?.value
    }

    private func localName(_ qualifiedName: String) -> String {
        qualifiedName.split(separator: ":", omittingEmptySubsequences: false)
            .last
            .map(String.init)?
            .lowercased() ?? qualifiedName.lowercased()
    }
}
