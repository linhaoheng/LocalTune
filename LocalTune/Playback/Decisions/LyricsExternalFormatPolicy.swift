import Foundation

/// 酷狗 **KRC** → 我们内部正文形态：`[mm:ss.xx]` ＋ 行内 `<mm:ss.xx>字`。
///
/// 纯函数、零 UIKit、能离线单测。
///
/// ## 🔴 为什么必须转（不是优化，是必需品）
///
/// KRC 的行首是**毫秒的 `[起,长]`**、行内字块是**相对行首的** `<起,长,0>`；而两端解析器
/// 都不认它：
///
/// - **编辑侧** `LyricsEditorPolicy.parse` 只认行首 `[mm:ss.xx]`（`leadingTimePattern` **带冒号**）；
/// - **播放侧** `LyricsParser` 更明确 —— 把「逐字毫秒档（`.lys`/`.yrc`/`.qrc`）·
///   相对毫秒行头 `[1234,5678]`」列进**不认**清单：碰到它们不报错，**但那些行会被丢掉**。
///
/// ## 🔴 红利：转出来自带逐字
///
/// 目标形态正好是 `LyricsSyllableTimingPolicy` 认的那套（行内 `<mm:ss.xx>`）⇒
/// 取回来的歌词**播放页直接逐字可唱，一个字都不用再打轴**。
///
/// ## 源格式（解密后实测，《晴天》68 行）
///
/// ```
/// [ti:晴天]
/// [ar:周杰伦]
/// …
/// [0,2250]<0,160,0>晴<160,160,0>天<320,160,0> <480,160,0>-…
/// ```
///
/// ## 规则
///
/// 1. **只认 `^[起(ms),长(ms)]` 开头的行**；其余整行丢（`[ti:]` `[ar:]` `[offset:]`… 全丢）。
///    🔴 顺手读 `[offset:]` —— **跟它应用**：读到非 0 就把换算出来的**时间整体减掉它**
///    （`Lyricify` `OffsetHelper.AddOffset`：`StartTime -= offset`）。
/// 2. **首/尾「制作信息块」里只删非署名行**（判据 = `LyricsCreditLinePolicy`）。
///    🔴 **词／曲／艺人／专辑是特例，一律保留**（含「歌名 - 歌手」与裸歌名行）；
///    编曲、混音、制作人、策划、腾讯翻译版权、`by` 这些照样删。
///    这是转换层**唯一**一处不"忠实搬运"，是**明确立的一条规则**（不是兜底、不是临时猜的）。
/// 3. **行级**：`[起,长]` → `[mm:ss.xx]`。**只用「起」**。
/// 4. 🔴 **字级：先换算成绝对，再写** —— KRC 的字块 `[行内相对起, 长, flag]` 是**相对行首**的 ⇒
///    **绝对 = 行起 ＋ 相对起**。（`.yrc` 的字级本来就是绝对；这是两源唯一的实质差别。）
/// 5. **行末补一个「末字结束」**：取**最后一个有文本的字块**的 `绝对起 ＋ 长`，行尾追加空时间块。
///    🔴 **一律补、不设例外、零长也照写**（转换层只搬运、不替下游判断）。
/// 6. **纯空白的字块**（词间空格）：**留文本、不写标记**。
/// 7. 🔴 **标题行统一改写成「歌名 - 艺人」**：头部块里第一行「标题行」
///    （裸歌名 或 含歌名＋艺人，判据 = `LyricsCreditLinePolicy.isTitleArtistLine`，
///    与块内保留同标准）⇒ 文本重写为 `歌名 - 艺人`，**并丢掉它的字块、降成整行级**——
///    原字块对着原行的字排（源档「艺人 - 歌名」「歌名 - 艺人」两种都有），重排后字块错位
///    ⇒ 扫光会亮错字；这行的时间本来就是上传者随手打的 ⇒ 丢块整行亮。
///    **只动头部块内这第一行**，正文一个字不碰；没传标题行的歌原样不动。
///
/// ## 归 `Playback/Decisions/` 的理由
///
/// 产物是**我们内部正文形态**，与播放侧解析同源（`LyricsSyllableTimingPolicy` 也在那儿）。
enum LyricsExternalFormatPolicy {

    // MARK: - 正则

    /// 行首 `[起(毫秒),长(毫秒)]`。
    ///
    /// ⚠️ 与 `LyricsParser.lineHeadPattern`（**带冒号**的 `[mm:ss]`）**不是**同一条 ——
    /// 那边匹配不上它，这正是本函数存在的理由。也**不要**为了"统一"把它们合并。
    private static let lineHeadPattern = try? NSRegularExpression(
        pattern: #"^\s*\[(\d+),(\d+)\]"#
    )

    /// 行内字块 `<相对起(毫秒),长(毫秒),flag>`（KRC 的 flag 恒为 `0`）。
    private static let syllablePattern = try? NSRegularExpression(
        pattern: #"<(\d+),(\d+),(\d+)>"#
    )

    /// 属性行 `[key:value]`（首部那几行，用来取 `offset`）。
    private static let attributePattern = try? NSRegularExpression(
        pattern: #"^\[([A-Za-z][A-Za-z0-9_-]*):(.*)\]\s*$"#
    )

    // MARK: - 入口

    /// 一份 KRC 明文 → 我们正文那套（`\n` 分隔的多行）。
    ///
    /// - Parameters:
    ///   - raw: 解密后的 KRC 原文。
    ///   - title: **这首曲子的歌名** —— 取自搜歌候选（`songname`），供信息行判据用。
    ///   - artists: **艺人** —— 取自搜歌候选（`singername`，`、` 拆开），供信息行判据用。
    /// - Returns: 正文；**一个字符都不剩 ⇒ 空串**（调用方据此判"这首歌没词"）。
    static func body(fromKRC raw: String, title: String, artists: [String]) -> String {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let offset = attributeOffset(in: lines)
        let lyricLines = lines.filter(isLyricLine)
        guard !lyricLines.isEmpty else { return "" }

        // 规则 2：制作信息删留 —— 头 / 中 / 尾（走 `removals` 一处）
        // ＋ 词/曲/艺人/专辑保留。署名混在块中间 ⇒ 按**行号集合**删。
        let track = LyricsCreditLinePolicy.TrackInfo(title: title, artists: artists)
        let texts = lyricLines.map { plainText(of: $0) }
        let drops = LyricsCreditLinePolicy.removals(texts, track: track)

        // 规则 7：标题行统一改写 —— 只在**头部块之内**找第一行「标题行」，
        // 块的边界与删留用的是同一套判据（`isInBlock`），正文一概不碰。
        var headingEnd = 0
        while headingEnd < texts.count,
              drops.contains(headingEnd)
                || LyricsCreditLinePolicy.isInBlock(texts[headingEnd], track: track) == .inBlock {
            headingEnd += 1
        }
        var titleRewrite: (index: Int, text: String)?
        for index in 0..<headingEnd where !drops.contains(index) {
            guard LyricsCreditLinePolicy.isTitleArtistLine(texts[index], track: track) == .titleArtist else { continue }
            titleRewrite = (index, unifiedTitleLine(track))
            break
        }

        return lyricLines.enumerated()
            .filter { !drops.contains($0.offset) }
            .map { output in
                if let rewrite = titleRewrite, output.offset == rewrite.index {
                    return convertTitleLine(output.element, text: rewrite.text, offset: offset)
                }
                return convertLine(output.element, offset: offset)
            }
            .joined(separator: "\n")
    }

    /// 改写后的标题行文本：`歌名 - 艺人`（艺人多位的按 `", "` 连，与 `TrackInfo.artist` 同口径）。
    ///
    /// 🔴 艺人为空 ⇒ 只写歌名；歌名空白 ⇒ 整条改写作废（不该有这种候选，防御）。
    private static func unifiedTitleLine(_ track: LyricsCreditLinePolicy.TrackInfo) -> String {
        let name = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if artist.isEmpty { return name }
        return "\(name) - \(artist)"
    }

    // MARK: - 私有 · 行

    /// 一行：`[起,长]<相对起,长,flag>字…` → `[mm:ss.xx]<mm:ss.xx>字…`。
    private static func convertLine(_ line: String, offset: Int?) -> String {
        guard let head = lineHead(in: line) else { return line }
        let bodyText = (line as NSString).substring(from: head.end)
        return "[\(stamp(head.startMilliseconds, offset: offset))]"
            + markingSyllables(bodyText, lineStartMilliseconds: head.startMilliseconds, offset: offset)
    }

    /// 标题行：`[起,长]<…>原文` → `[mm:ss.xx]歌名 - 艺人` —— **不带任何字块**（整行级）。
    ///
    /// 🔴 为什么丢字块见头注规则 7：原块对着原行字排，重排后错位会亮错字；
    /// 行时间（`stamp` 同口径，含 offset 平移）是真的，保留。
    private static func convertTitleLine(
        _ line: String, text: String, offset: Int?
    ) -> String {
        guard let head = lineHead(in: line) else { return line }
        return "[\(stamp(head.startMilliseconds, offset: offset))]\(text)"
    }

    /// 行内：`<相对起,长,flag>字…` → `<mm:ss.xx>字…`，**行末再补一个结束标记**。
    ///
    /// 时间 = **行起 ＋ 字块自己的相对起**（KRC 相对 ⇒ 这里累加；`.yrc` 绝对那套已删）。
    ///
    /// 🔴 **纯空白的字块不写标记、只留那一段文本**：它是词间空格。写个 `<00:00.00>` 会把正文
    /// 弄脏（编辑器「原文」页、海报都会看见）；连文本一起删掉又会把英文粘成 `Shiningdays,`。
    /// 取"留文本、去标记"（与 `LyricsSyllableTimingPolicy.syllables(inLine:)` 对空块的读法一致）。
    ///
    /// ⚠️ **零长但有文本**的字块照常写**它自己的**起点标记，**也照补行末结束**（即便同值）。
    private static func markingSyllables(
        _ text: String, lineStartMilliseconds: Double, offset: Int?
    ) -> String {
        guard let syllablePattern else { return text }
        let ns = text as NSString
        let matches = syllablePattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        // 首个字块之前若还有文本（实测没有，防御性），原样补回去 —— 不能吞。
        if matches[0].range.location > 0 {
            result += ns.substring(with: NSRange(location: 0, length: matches[0].range.location))
        }

        // 最后一个**有文本**字块的绝对结束时间 —— 行末那个结束标记由它算。
        // 末尾的纯空白字块（词间空格）没有时间信息，不算"末字"。
        var lastTimedEnd: Double?

        for (index, match) in matches.enumerated() {
            let relativeStart = Double(ns.substring(with: match.range(at: 1))) ?? 0
            let length = Double(ns.substring(with: match.range(at: 2))) ?? 0
            let textFrom = match.range.location + match.range.length
            let textTo = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let chunk = ns.substring(with: NSRange(location: textFrom, length: textTo - textFrom))

            let absoluteStart = lineStartMilliseconds + relativeStart
            if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result += chunk
            } else {
                result += "<\(stamp(absoluteStart, offset: offset))>" + chunk
                lastTimedEnd = absoluteStart + length
            }
        }

        if let lastTimedEnd {
            result += "<\(stamp(lastTimedEnd, offset: offset))>"
        }
        return result
    }

    /// 行首那一个 `[起,长]` —— 起换成**毫秒**（保留原值，平移在 `stamp` 里做）。
    private struct LineHead {
        let startMilliseconds: Double
        /// 行首那一段 `[…, …]`（含前导空白）之后的**字符串下标**。
        let end: Int
    }

    private static func lineHead(in line: String) -> LineHead? {
        guard let pattern = lineHeadPattern else { return nil }
        let ns = line as NSString
        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              match.range.location == 0,
              let milliseconds = Double(ns.substring(with: match.range(at: 1)))
        else { return nil }
        return LineHead(startMilliseconds: milliseconds, end: match.range.location + match.range.length)
    }

    /// 是不是「歌词行」（`^[起,长]` 开头）—— 其余（属性行、空行、杂行）一律丢。
    private static func isLyricLine(_ line: String) -> Bool {
        guard let pattern = lineHeadPattern else { return false }
        let ns = line as NSString
        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
        else { return false }
        return match.range.location == 0
    }

    /// 一行歌词的**纯文本**（把行首那一段与所有字块标记都剥掉）—— 喂给信息行判据。
    ///
    /// 取自 `KrcParser` 那边 `SyllableLineInfo.Text`（＝各字块文本拼起来）的口径。
    private static func plainText(of line: String) -> String {
        guard let head = lineHead(in: line), let syllablePattern else { return "" }
        let ns = line as NSString
        let bodyText = ns.substring(from: head.end) as NSString
        let matches = syllablePattern.matches(
            in: bodyText as String, range: NSRange(location: 0, length: bodyText.length)
        )
        guard !matches.isEmpty else { return "" }

        var result = ""
        if matches[0].range.location > 0 {
            result += bodyText.substring(with: NSRange(location: 0, length: matches[0].range.location))
        }
        for (index, match) in matches.enumerated() {
            let from = match.range.location + match.range.length
            let to = index + 1 < matches.count ? matches[index + 1].range.location : bodyText.length
            result += bodyText.substring(with: NSRange(location: from, length: to - from))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 私有 · 属性行 / offset

    /// 读首部属性行里的 `[offset:]`（毫秒，可正可负）。没有 ⇒ `nil`（⇒ 不平移）。
    ///
    /// 只从**最前面**连着的那几行属性行里读（`Lyricify` `ParseGeneralAttributesToLyricsData`
    /// 碰到第一行非属性行就 `break`）。
    private static func attributeOffset(in lines: [String]) -> Int? {
        var offset: Int?
        for line in lines {
            guard let attribute = attribute(of: line) else { break }
            if attribute.key == "offset", let value = Int(attribute.value) {
                offset = value
            }
        }
        return offset
    }

    /// `[key:value]` → 键值对；不是属性行 ⇒ `nil`。
    private static func attribute(of line: String) -> (key: String, value: String)? {
        guard let pattern = attributePattern else { return nil }
        let ns = line as NSString
        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              match.range.location == 0
        else { return nil }
        let key = ns.substring(with: match.range(at: 1))
        let value = ns.substring(with: match.range(at: 2))
        return (key, value)
    }

    // MARK: - 私有 · 时间

    /// 毫秒 → `mm:ss.xx`，**先减 `offset`（若有）**。
    ///
    /// `Lyricify` `OffsetHelper.AddOffset` 对每个时间做 `StartTime -= offset`（offset 也是毫秒）
    /// ⇒ 这里同口径。负值由 `LyricsEditorPolicy.format` 钳到 0（正文写不出负时间）。
    private static func stamp(_ milliseconds: Double, offset: Int?) -> String {
        let shifted = offset.map { milliseconds - Double($0) } ?? milliseconds
        return LyricsEditorPolicy.format(shifted / 1000)
    }
}
