import Foundation

/// 「一行正文里的逐字标记」—— 界面上**显示什么**、`±` **还能不能动**。
///
/// 纯函数、零 UIKit、能离线单测。
///
/// ## 🔴 它不解析逐字，也不改正文
///
/// 逐字时间**只有一份真相**：`LyricsLine.syllables`（解析器吐出来的模型值）。
/// 编辑页把它投影成 `LyricsEditorSyllable` 直接画（`LyricsEditorViewModel.syllables(inRow:)`），
/// 打点 / 微调改的也是那份模型 —— 不存在"从正文现解析、改完再把正文写回去"那条路。
///
/// 这里只剩两件**只看不改**的事：
/// - 把正文里的 `<mm:ss.xx>` 剥掉，得到正文框要显示的纯文字（`plainText`）；
/// - 夹界：`±` 键按到哪儿就该停（`nudgeRoom`）。
///
/// ⚠️ 曾有过 `syllables(inLine:)` / `replacingStart` / `nudgingStart` / `shiftingStarts`
/// 一整套（从正文切逐字、改文本字节），2026-11-17 删。它与模型里的 `syllables` 是**两份真相**，
/// 且"行末空块算一格"的读法和模型里的句尾格（`LyricSyllable.isLineEnd`）互相冲突 ——
/// 谁照着它写谁错。别把这套请回来。
enum LyricsSyllableTimingPolicy {

    /// 行内逐字标记：`<mm:ss>` / `<mm:ss.xx>` / `<mm:ss:xx>` / `<mm:ss.xxx>`。
    ///
    /// 与播放侧 `LRCLyricsParser.inlineWordPattern` **同一套写法**；这里只用来**剥除**，不解析时间。
    ///
    /// 敢吞 `try?` 这一下：模式是**字面量**、编译期就定死了，真编不出来 = 模式写错
    /// （开发期错误，运行期不会发生）—— 吞掉后走"这一行没有标记"那条路。
    private static let markerRegex = try? NSRegularExpression(
        pattern: #"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>"#
    )

    // MARK: - 显示

    /// 一行正文 → **去掉逐字标记后剩下的歌词本身**。
    ///
    /// 正文框里显示的就是它：`[00:12.30]<00:12.30>眼<00:12.80>泪` 显示成 `眼泪`。
    ///
    /// 🔴 **只删标记那几个字节**，其余（空格、标点）一个不动 —— 这是"看的那张脸"，
    /// 不是另一份正文：模型里那份始终带着标记。
    static func plainText(inLine line: String) -> String {
        guard let markerRegex else { return line }
        return markerRegex.stringByReplacingMatches(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length),
            withTemplate: ""
        )
    }

    // MARK: - 微调界

    /// 第 `index` 个字的 `±` **还能不能动**。吐 `NudgeAvailability`。
    ///
    /// 🔴 判断在**这里**，不在视图里：视图手上只有当前这一个字，
    /// 看不见邻居和句子时间就答不出"到头了没有"。
    ///
    /// 两道界：
    /// - **下界** = 前一个字的起点，与**本行句子时间**取大（没有前一个字就只认句子时间；
    ///   句子也没打轴 ⇒ 0）。字时间不许比句子时间还早 —— 不跟句子时间联动改轴时，
    ///   仍要守这条不变式。
    /// - **上界** = 后一个字的起点 —— 否则一按就可能把词序按倒，保存出**倒序的逐字**。
    ///   句尾那一格没有上邻 ⇒ 不封顶。
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

    /// 上界：后一字起点；末字（含句尾那一格）无上邻 ⇒ 不封顶。
    private static func upperBound(
        for index: Int,
        in syllables: [LyricsEditorSyllable]
    ) -> TimeInterval {
        index + 1 < syllables.count
            ? syllables[index + 1].start
            : TimeInterval.greatestFiniteMagnitude
    }
}
