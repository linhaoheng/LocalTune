import Foundation

/// 「一行正文里的逐字标记」—— **取出来 / 改掉某一个 / 现在唱到第几个**。
///
/// 纯函数、零 UIKit、能离线单测。
///
/// ## 🔴 为什么逐字落在这一层、而不进模型
///
/// `LyricsEditorLine` 只有 `time` + `text`。逐字块**每次从正文现解析**；
/// 打点 / 微调 = 只替换**第 k 个** `<mm:ss.xx>` 那几个字节、其余一个不动
/// ⇒ 不存在"两份表示谁保证一致"的问题。
///
/// ## ⚠️ 只认行内 `<mm:ss.xx>` 一种标记
///
/// 与播放侧的 `LyricsParser.inlineWordPattern` **同一套语义**。方括号逐字
/// `[00:01]词[00:02]词` 不在这里管：行首那一个已经被 `LyricsEditorPolicy.parse`
/// 当**行时间**拿走了，剩下的 `词[00:02]词` 不再成词。
///
/// 🔴 **两处正则必须同时改**：这里是编辑侧、`LyricsParser` 是播放侧。
/// 谁改了语义而另一处没跟上，就会出现"编辑器里看着对、播起来对不上"。
///
/// ## 🔴 行末那一格：「这一行结束」
///
/// 正文里最后一个标记若**后面没有文字**（`…<00:29.79>`），它就是**末字的结束时间**。
/// 它**算一格**（`syllables(inLine:)` 的最后一项），界面上看得见、点得着、打得进时间 ——
/// 不然用户没有任何地方能把"这一行唱到几秒"写下来。
///
/// ⚠️ 它跟**行内**的空块不是一回事：行内的空块（`<a>甲<b><c>乙` 中间那个 `b`）仍然跳过。
/// ⚠️ 那一格的 `text` 是**空串**（正文里不写符号）—— 所以逐字条上它按"空文本"画
/// （`LyricsEditorSyllableStripView.visibleText` ⇒ `--`）。
enum LyricsSyllableTimingPolicy {

    /// 行内逐字标记：`<mm:ss>` / `<mm:ss.xx>` / `<mm:ss:xx>` / `<mm:ss.xxx>`。
    ///
    /// 敢吞 `try?` 这一下：模式是**字面量**、编译期就定死了，真编不出来 = 模式写错
    /// （开发期错误，运行期不会发生）—— 吞掉后走"这一行没有逐字"那条路。
    private static let markerRegex = try? NSRegularExpression(
        pattern: #"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>"#
    )

    // MARK: - 取

    /// 一行正文 → 逐字块。没有标记 ⇒ 空数组（这一行按行级处理）。
    ///
    /// 🔴 **行末那个空块也算一项**（见类 doc「行末那一格」）—— 所以"格子比字多一个"
    /// 是正常的，不是解析错。
    static func syllables(inLine line: String) -> [LyricsEditorSyllable] {
        guard let markerRegex else { return [] }
        let ns = line as NSString
        let matches = markerRegex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        var result: [LyricsEditorSyllable] = []
        for (index, match) in matches.enumerated() {
            guard let start = timestamp(in: ns, match: match) else { continue }
            let textStart = match.range.location + match.range.length
            let textEnd = index + 1 < matches.count
                ? matches[index + 1].range.location
                : ns.length
            let raw = ns.substring(with: NSRange(location: textStart, length: textEnd - textStart))
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空块 = 上一个词的结束时间被**写死**了（播放侧照同一个读法处理）。
            //
            // 🔴 **行内**的空块不当一个词；**行末**那一个（最后一个标记、后面没有文字）**要算一格** ——
            // 它就是「这一行结束」，界面上得有它才能看见 / 选中 / 打点。
            // 那一格的 `text` 保持空串：正文不写符号（符号写进去，播放页 / 海报 / 原文页都会冒出来）。
            if text.isEmpty, index != matches.count - 1 { continue }
            result.append(
                LyricsEditorSyllable(
                    text: text,
                    start: start,
                    fullRange: NSRange(
                        location: match.range.location,
                        length: textEnd - match.range.location
                    ),
                    markerRange: match.range
                )
            )
        }
        return result
    }

    /// 一行正文 → **去掉逐字标记后剩下的歌词本身**。
    ///
    /// 逐行页正文框里显示的就是它：逐字时间只由下面那条逐字块承担，不夹在歌词中间
    /// `[00:12.30]<00:12.30>眼<00:12.80>泪`
    /// 显示成 `眼泪`。
    ///
    /// 🔴 **只删标记那几个字节**，其余（空格、标点、换行）一个不动 —— 所以这是"看的那张脸"，
    /// 不是另一份正文：模型里那份始终带着标记，改字才作废（见 `replacingStart` 那条口径）。
    static func plainText(inLine line: String) -> String {
        guard let markerRegex else { return line }
        return markerRegex.stringByReplacingMatches(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length),
            withTemplate: ""
        )
    }

    // MARK: - 改

    /// 把第 `index` 个字的起点改成 `time` —— 返回新的一行正文。
    ///
    /// 🔴 **只换那一个标签的字节**，其余一个字不动。所以连"打开一次就把
    /// `[00:12.30]` 规范化成 `[00:12.300]`"那类坑都天然免疫。
    ///
    /// ⚠️ 下标指到**行末那一格**时，换的就是「这一行结束」那个标记 —— 同一个动作、
    /// 同一段字节，只是那格的语义是"结束"不是"起点"（见类 doc）。
    ///
    /// - Returns: 新的一行正文；**下标不合法** ⇒ `nil`（调用方保持原样）。
    static func replacingStart(
        _ time: TimeInterval, ofSyllableAt index: Int, inLine line: String
    ) -> String? {
        let items = syllables(inLine: line)
        guard items.indices.contains(index) else { return nil }
        let ns = line as NSString
        let marker = "<\(LyricsEditorPolicy.format(time))>"
        return ns.replacingCharacters(in: items[index].markerRange, with: marker)
    }

    /// 微调第 `index` 个字的起点（`±0.1s` 那一对键）。
    ///
    /// 🔴 **夹在两道界之间**：
    /// - **下界** = 前一个字的起点，与**本行句子时间**取大（没有前一个字就只认句子时间；
    ///   句子也没打轴 ⇒ 0）。字时间不许比句子时间还早 —— 不跟句子时间联动改轴时，
    ///   仍要守这条不变式。
    /// - **上界** = 后一个字的起点 —— 否则一按就可能把词序按倒，保存出**倒序的逐字**。
    ///
    /// - Parameter lineTime: 这一行的句子时间（`LyricsEditorLine.time`）；未打轴传 `nil`。
    /// - Returns: 新的一行正文；**夹完之后没变化** / 下标不合法 ⇒ `nil`（调用方不必重画）。
    static func nudgingStart(
        by delta: TimeInterval,
        syllableAt index: Int,
        inLine line: String,
        lineTime: TimeInterval?
    ) -> String? {
        let items = syllables(inLine: line)
        guard items.indices.contains(index) else { return nil }
        let lower = lowerBound(for: index, in: items, lineTime: lineTime)
        let upper = upperBound(for: index, in: items)
        let target = min(max(items[index].start + delta, lower), upper)
        guard target != items[index].start else { return nil }
        return replacingStart(target, ofSyllableAt: index, inLine: line)
    }

    /// 第 `index` 个字的 `±` **还能不能动** —— 与 `nudgingStart` **同一对界**。吐 `NudgeAvailability`。
    ///
    /// 🔴 判断在**这里**，不在视图里：视图手上只有当前这一个字，
    /// 看不见邻居和句子时间就答不出"到头了没有"。
    static func nudgeRoom(
        in syllables: [LyricsEditorSyllable],
        at index: Int,
        lineTime: TimeInterval?
    ) -> NudgeAvailability {
        guard syllables.indices.contains(index) else { return .none }
        let lower = lowerBound(for: index, in: syllables, lineTime: lineTime)
        let upper = upperBound(for: index, in: syllables)
        let start = syllables[index].start
        switch (start > lower, start < upper) {
        case (true, true): return .both
        case (true, false): return .decreaseOnly
        case (false, true): return .increaseOnly
        case (false, false): return .none
        }
    }

    /// 下界：前一字起点 与 句子时间 取大（首字没有前邻 ⇒ 只认句子时间 / 0）。
    private static func lowerBound(
        for index: Int,
        in syllables: [LyricsEditorSyllable],
        lineTime: TimeInterval?
    ) -> TimeInterval {
        let neighbor = index > 0 ? syllables[index - 1].start : 0
        return max(neighbor, lineTime ?? 0)
    }

    /// 上界：后一字起点；末字无上邻 ⇒ 不封顶。
    private static func upperBound(
        for index: Int,
        in syllables: [LyricsEditorSyllable]
    ) -> TimeInterval {
        index + 1 < syllables.count
            ? syllables[index + 1].start
            : TimeInterval.greatestFiniteMagnitude
    }

    // MARK: - 整体平移

    /// 这一行正文里**所有**逐字标记的起点 —— 给「全局偏移」算整份最左端用。
    ///
    /// 🔴 **不能拿 `syllables(inLine:)` 顶替**：那个跳过「行内空块」
    /// （`<a>甲<b><c>乙` 中间那个 `b`，见类 doc）。它也是写在正文里的时间戳、也得跟着平移 ——
    /// 漏掉它，同一行里会剩下一套没挪的数。
    static func markerStarts(inLine line: String) -> [TimeInterval] {
        markers(inLine: line).map { $0.start }
    }

    /// 把这一行正文里**所有** `<mm:ss.xx>` 标记整体加上 `delta` 秒（负数 = 提前）。
    ///
    /// 🔴 **只换标记那几个字节**、其余正文一个不动（同 `replacingStart`）——
    /// 所以连"打开一次就被规范化"那类坑都天然免疫。
    /// 没有标记 ⇒ **原样返回**（这一行按行级处理）。
    static func shiftingStarts(inLine line: String, by delta: TimeInterval) -> String {
        let items = markers(inLine: line)
        guard delta != 0, !items.isEmpty else { return line }
        let result = NSMutableString(string: line)
        // 从后往前换：已经换过的标记长度会变，倒着走就不用重算前面那些 range。
        for item in items.reversed() {
            result.replaceCharacters(
                in: item.range,
                with: "<\(LyricsEditorPolicy.format(item.start + delta))>"
            )
        }
        return result as String
    }

    // MARK: - 现在唱到第几个

    /// 播放到 `playbackTime` 时第几个字在唱 —— **最后一个起点 ≤ 播放时间的字**。
    ///
    /// 还没到第一个字 ⇒ `nil`（第一个字之前不该有高亮，跟 `LyricsPlaybackPolicy.activeLineIndex`
    /// 同一条口径）。
    ///
    /// ⚠️ **只有打轴页的「逐字游标」要跟播放头**（primuse 的 `timingSyllableIndex`，
    /// `LyricsEditorView.swift:2874`）。🔴 **逐行页不用它** —— 那一页的逐字高亮只认用户点选
    /// 本函数留给打轴页接线用。
    static func activeSyllableIndex(
        in syllables: [LyricsEditorSyllable], at playbackTime: TimeInterval
    ) -> Int? {
        var result: Int?
        for (index, syllable) in syllables.enumerated() {
            guard syllable.start <= playbackTime else { break }
            result = index
        }
        return result
    }

    // MARK: - 私有

    /// 一行正文里**每一个** `<mm:ss.xx>` 标记（含 `syllables(inLine:)` 会跳过的行内空块）。
    ///
    /// 与 `syllables(inLine:)` 的差别只在**筛不筛**：那个吐"字"（行内空块跳过），
    /// 这个吐**全部标记** —— 整体平移要把每一个都挪走，漏一个就剩下一套没动的数。
    private static func markers(inLine line: String) -> [(range: NSRange, start: TimeInterval)] {
        guard let markerRegex else { return [] }
        let ns = line as NSString
        return markerRegex
            .matches(in: line, range: NSRange(location: 0, length: ns.length))
            .compactMap { match in
                guard let start = timestamp(in: ns, match: match) else { return nil }
                return (range: match.range, start: start)
            }
    }

    /// 匹配里的 `mm` / `ss` / 小数 → 秒。
    ///
    /// 小数位按**写了几位**解释（与 `LyricsParser.parseTimestamp` 同一套）：
    /// `.5` 是半秒、不是 5 毫秒。
    private static func timestamp(in ns: NSString, match: NSTextCheckingResult) -> TimeInterval? {
        guard let minutes = Double(ns.substring(with: match.range(at: 1))),
              let seconds = Double(ns.substring(with: match.range(at: 2)))
        else { return nil }

        var fraction = 0.0
        let fractionRange = match.range(at: 3)
        if fractionRange.location != NSNotFound,
           let raw = Double(ns.substring(with: fractionRange)) {
            fraction = raw / pow(10, Double(fractionRange.length))
        }

        let result = minutes * 60 + seconds + fraction
        return result.isFinite ? result : nil
    }
}
