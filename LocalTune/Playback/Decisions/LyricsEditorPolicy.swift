import Foundation

/// 「编辑歌词」页的**全部语义** —— 解析 / 导出 / 问题检测 / 整体平移 / 编辑动作。
///
/// ## 为什么全在一个枚举里
///
/// 宪法 §三·判断归位：**判断写成纯函数**、返回 enum 不返回 Bool、**能脱离 UIKit 单测**。
/// 这里一个 UIKit 字样都没有 —— `LocalTuneTests/LyricsEditorPolicyTests.swift` 直接把整个文件拷出去
/// 就能跑（`ios-offline-swift-verify` 那套套路）。页面只做两件事：把用户动作翻成对这一族的调用、把结果画出来。
///
/// 📍 解析 / 导出 / 格式化在别处是**模型自己**的方法、问题检测散在页面里；
/// 这里按本工程的分层把**值**（`LyricsEditorLine`）和**判断**（这里）分开。
///
/// ## 两条**有意不照常规做法**的地方
///
/// 1. **正文原样保留**：行内任何东西（含 4d 的逐字 `<mm:ss>` 标记）都当普通正文，不识别、不剥离、
///    不报警告 —— 打开一次再保存会把模型承载不了的东西丢掉，我们不丢。
/// 2. **整体平移用「整份统一 clamp」**：不逐行 clamp（那会让靠前的句子先塌到 0 挤成一堆、
///    行距**永久破坏且不可逆**，§B10）。
enum LyricsEditorPolicy {

    // MARK: - 数值口径

    /// 保存前的问题清单**最多列几条**。
    ///
    static let saveIssueLimit = 4

    /// 行首时间戳：`[mm:ss]` / `[mm:ss.xx]` / `[mm:ss:xx]` / `[mm:ss.xxx]`。
    ///
    /// 🔴 **锚在行首**（`^`）：行中间出现的 `[00:12]` 是**正文的一部分**，原样留着 ——
    /// 参考工程那份没锚（用 `last` 取最后一个匹配），会把「abc[00:12]」这种当成时间戳前缀、
    /// 把 `abc` 吃掉。我们不做那件事。
    ///
    /// 敢吞 `try?` 这一下：这是**字面量**正则，模式在编译期就定死了；真编不出来 = 模式写错
    /// （开发期错误，运行期不会发生）—— 吞掉后 `nil` 走「这一行没时间戳」那条路。
    private static let leadingTimePattern = try? NSRegularExpression(
        pattern: #"^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
    )

    // MARK: - 解析 / 导出

    /// 一段歌词原文 → 行数组。
    ///
    /// - 整段**先 trim**：头尾的空行不保留。
    /// - 全部空白 ⇒ **一行空行**（不是零行）—— 这样「逐行」页永远有一行可编辑，
    ///   上下都这么做。
    static func parse(_ raw: String) -> [LyricsEditorLine] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [LyricsEditorLine(time: nil, text: "")] }
        return trimmed.components(separatedBy: .newlines).map(parseLine)
    }

    /// 行数组 → 歌词原文。`[mm:ss.xx]正文`；没打轴的行**原样输出**（不加空时间戳）。
    static func export(_ lines: [LyricsEditorLine]) -> String {
        lines.map { line in
            guard let time = line.time else { return line.text }
            return "[\(format(time))]\(line.text)"
        }
        .joined(separator: "\n")
    }

    /// 秒 → `mm:ss.xx`。
    ///
    /// 🔴 格式是 `String(format: "%02d:%05.2f", minutes, seconds)`：
    /// **照抄**。⚠️ 所以导出会把 `[00:05.2]` 规范成 `[00:05.20]`、把三位小数截成两位 ——
    /// 我们靠「没改就不算改」（见 `isEdited`）避免"一打开就变脏"。
    static func format(_ time: TimeInterval) -> String {
        let clamped = max(0, time)
        let minutes = Int(clamped) / 60
        let seconds = clamped - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, seconds)
    }

    /// 打轴页中间格等处的占位：没打轴画 `--:--`（保高度；空串会把栈挤扁）。
    ///
    /// ⚠️ **不是**逐行页时间键 —— 逐行未打轴是「打点」键（`unstampedLineTimeButtonTitle`）。
    static func timeButtonTitle(for time: TimeInterval?) -> String {
        guard let time else { return "--:--" }
        return format(time)
    }

    /// 逐行页时间键：还没打轴时面上的字（那支键**只有这两个字**，没有图标）。
    static let unstampedLineTimeButtonTitle = "打点"

    // MARK: - 问题检测

    /// 时间 → **厘秒**。时间比较一律先量化。
    ///
    /// 🔴 算法是 `Int((time * 100).rounded())`。
    /// **为什么要先量化**：`1.0004` 和 `1.0001` 其实是同一个时刻（两条解析路径算出来的同一秒），
    /// 但两个 `Double` **不相等** ⇒ 直接比浮点数会**漏掉**这处重复；量化到厘秒再比才抓得住。
    /// （反过来，差到 1 厘秒以上就如实算两处，不会因为"差一点点"乱报。）
    static func centiseconds(_ time: TimeInterval) -> Int {
        Int((time * 100).rounded())
    }

    /// 这一行是不是空行（全空白）。
    ///
    /// 吐的 `LyricsLineBlankness` 在 `Playback/Model/LyricsEditorLine.swift`。
    static func isBlank(_ text: String) -> LyricsLineBlankness {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .blank : .hasText
    }

    /// **每一行**的问题 —— ⚠️ 返回值**跟 `lines` 一一对应、同长**（行 cell 直接按行号取）。
    static func rowIssues(in lines: [LyricsEditorLine]) -> [[LyricIssueKind]] {
        lines.indices.map { rowIssues(at: $0, in: lines) }
    }

    /// 保存前那串确认文案：每条 `N行，问题`（`N` 是 1-based 行号），最多 `saveIssueLimit` 条。
    ///
    /// ⚠️ 跟行内角标**不完全一样**：**空行不算**（`saveIssueRows` 先跳过空行），
    /// 所以这里只可能出现 未打轴 / 时间重复 / 时间倒序 三种。产生顺序也照行内角标那一套。
    static func saveIssueMessages(in lines: [LyricsEditorLine]) -> [String] {
        var messages: [String] = []
        var seenCentiseconds = Set<Int>()
        var previousTimed: TimeInterval?

        for (index, line) in lines.enumerated() {
            guard isBlank(line.text) == .hasText else { continue }
            guard let time = line.time else {
                messages.append("\(index + 1)行，\(LyricIssueKind.untimed.label)")
                continue
            }
            let key = centiseconds(time)
            if seenCentiseconds.contains(key) {
                messages.append("\(index + 1)行，\(LyricIssueKind.duplicate.label)")
            } else {
                seenCentiseconds.insert(key)
            }
            if let previousTimed, time < previousTimed {
                messages.append("\(index + 1)行，\(LyricIssueKind.reversed.label)")
            }
            previousTimed = time
        }
        return Array(messages.prefix(saveIssueLimit))
    }

    /// 这一趟"未打轴"的行有几行（打轴面板上那句汇总）。
    ///
    /// 数**所有** `time == nil` 的行（含空行）—— 空行本来也不该打轴。
    static func untimedCount(in lines: [LyricsEditorLine]) -> Int {
        lines.filter { $0.time == nil }.count
    }

    // MARK: - 改（逐行编辑动作）

    /// 给某一行打上时间（负数**夹到 0**）。
    ///
    /// 下标越界就**原样返回** —— 不崩、也不悄悄改错行。
    static func settingTime(
        _ time: TimeInterval, at index: Int, in lines: [LyricsEditorLine]
    ) -> [LyricsEditorLine] {
        guard lines.indices.contains(index) else { return lines }
        var next = lines
        next[index].time = max(0, time)
        return next
    }

    /// 改某一行的正文。
    static func settingText(
        _ text: String, at index: Int, in lines: [LyricsEditorLine]
    ) -> [LyricsEditorLine] {
        guard lines.indices.contains(index) else { return lines }
        var next = lines
        next[index].text = text
        return next
    }

    /// 把**这一行整体**挪 `delta` 秒（负数 = 提前）—— 行时间 ＋ 正文里的逐字标记**一起挪**。
    ///
    /// 🔴 **不是只挪行时间** —— 那会让这一行的逐字跟行首脱开（编辑器里看着对、播起来逐字偏）。
    /// 与 `shifted` 同一条口径，只是范围从"整份"缩到"这一行"：**撞到 0 就这一行一起停住**
    /// （界取**这一行最早的时间戳**，逐字也算）—— 不是只把行时间夹在 0、逐字各自塌。
    ///
    /// ⚠️ 这一行**还没打过轴**时，以 `base`（页面给"当前播放时间"）当基准 ——
    /// 不然"没时间"没法做加减。
    static func nudging(
        _ delta: TimeInterval, at index: Int, base: TimeInterval, in lines: [LyricsEditorLine]
    ) -> [LyricsEditorLine] {
        guard lines.indices.contains(index) else { return lines }
        let line = lines[index]
        let anchor = line.time ?? base
        let earliest = min(
            anchor,
            LyricsSyllableTimingPolicy.markerStarts(inLine: line.text).min() ?? anchor
        )
        let applied = max(delta, -earliest)
        var next = lines
        next[index].text = LyricsSyllableTimingPolicy.shiftingStarts(inLine: line.text, by: applied)
        return settingTime(anchor + applied, at: index, in: next)
    }

    // MARK: - 整体平移

    /// 给**这一份里所有时间戳**加上同一个偏移（负数 = 整体提前）。
    ///
    /// 🔴 **时间戳有两处**：行首 `[mm:ss.xx]`（进 `line.time`）和正文里的逐字 `<mm:ss.xx>`
    /// **两处一起挪** —— 只挪行时间的话，编辑器里看着对、播起来逐字整体偏。
    ///
    /// 🔴 **不是逐行 clamp** —— 逐行各自夹到 0 的话，靠前的句子会先塌到一堆，
    /// **行与行之间的距离永久破坏且不可逆**（primuse `LyricsEditorDocument.swift:411-441` 专门警告过这件事）。
    ///
    /// 这里的做法：**先算出"整份最多能往左挪多少"，再把这一个偏移量应用到每一处** ——
    /// 撞到 0 的时候**整份一起停住**，行距、行内逐字间距一个不动。⇒ 这就是照 primuse 的做法修掉那个错。
    ///
    /// ⚠️ 算"最早那一个"时**逐字也算数**：只认行时间的话，一行"行时间没事、逐字贴着 0"的会被推成负数。
    ///
    /// - Parameter delta: 相对**传进来这一份**的偏移（秒）。
    /// - Returns: 新的一份；`lines` 里**一个时间戳都没有**（或 `delta == 0`）时**原样返回**。
    static func shifted(_ lines: [LyricsEditorLine], by delta: TimeInterval) -> [LyricsEditorLine] {
        guard delta != 0 else { return lines }
        guard let earliest = earliestTimestamp(in: lines) else { return lines }
        let applied = max(delta, -earliest)
        guard applied != 0 else { return lines }
        return lines.map { line in
            LyricsEditorLine(
                time: line.time.map { max(0, $0 + applied) },
                text: LyricsSyllableTimingPolicy.shiftingStarts(inLine: line.text, by: applied)
            )
        }
    }

    // MARK: - 改动判定

    /// 用户**实际改过没有**。
    ///
    /// 🔴 比的是**行数据**、不是"导出后的字符串"：导出会把 `[00:05.2]` 规范成 `[00:05.20]`，
    /// 拿字符串比等于**一打开就显示有改动**（primuse `LyricsEditorDocument.committedText` 踩过同一个坑，
    /// §D.10）。比行数据就不会 —— 用户没动，两边的行数组一模一样。
    static func isEdited(
        _ lines: [LyricsEditorLine], comparedTo original: [LyricsEditorLine]
    ) -> LyricsEditState {
        lines != original ? .edited : .unchanged
    }

    // MARK: - 私有

    /// 这一份里**所有时间戳**里最早的那一个 —— 行首 `[mm:ss.xx]` 与正文里的逐字 `<mm:ss.xx>` 一起算。
    ///
    /// 🔴 两处必须一起算：只认行时间的话，一行"行时间没事、逐字贴着 0"的会被推成负数。
    ///
    /// - Returns: 一个时间戳都没有 ⇒ `nil`（这份没什么可挪的）。
    private static func earliestTimestamp(in lines: [LyricsEditorLine]) -> TimeInterval? {
        var starts: [TimeInterval] = []
        for line in lines {
            starts.append(contentsOf: LyricsSyllableTimingPolicy.markerStarts(inLine: line.text))
            if let time = line.time { starts.append(time) }
        }
        return starts.min()
    }

    /// 一行的解析：**行首那一个** `[mm:ss.xx]` → `time`，**其余原样进正文**。
    ///
    /// 🔴 `[t1][t2]词` 这种一行多时间戳的写法：取**第一个**当行时间，
    /// 第二个连同它后面的字一起当**正文**留着 ⇒ 往返一圈**一个字都不丢**。
    /// （参考工程那份取的是**最后一个**、把前面的吃掉 —— 那是静默丢数据，我们不学。）
    private static func parseLine(_ line: String) -> LyricsEditorLine {
        guard let prefix = leadingTimestamp(in: line) else {
            return LyricsEditorLine(time: nil, text: line)
        }
        let ns = line as NSString
        let text = ns.substring(from: prefix.range.location + prefix.range.length)
        return LyricsEditorLine(time: prefix.time, text: text)
    }

    private struct TimestampPrefix {
        let time: TimeInterval
        let range: NSRange
    }

    private static func leadingTimestamp(in line: String) -> TimestampPrefix? {
        let ns = line as NSString
        guard let pattern = leadingTimePattern,
              let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              match.range.location == 0
        else { return nil }

        let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
        let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0

        var fraction = 0.0
        let fractionRange = match.range(at: 3)
        if fractionRange.location != NSNotFound {
            // `.5` / `.25` / `.234` 一律按**三位**读（补零到 3 位再除 1000）——
            // 所以 `.5` 是半秒、不是 5 毫秒。
            let raw = ns.substring(with: fractionRange)
            let padded = raw.padding(toLength: 3, withPad: "0", startingAt: 0)
            fraction = (Double(padded) ?? 0) / 1000
        }

        return TimestampPrefix(
            time: minutes * 60 + seconds + fraction,
            range: match.range
        )
    }

    /// 第 `index` 行的问题（行内角标用，**含**「歌词为空」）。
    private static func rowIssues(at index: Int, in lines: [LyricsEditorLine]) -> [LyricIssueKind] {
        let line = lines[index]
        guard isBlank(line.text) == .hasText else { return [.empty] }
        guard let time = line.time else { return [.untimed] }

        var issues: [LyricIssueKind] = []
        let key = centiseconds(time)

        let duplicatedEarlier = lines[..<index].contains { earlier in
            guard let earlierTime = earlier.time, isBlank(earlier.text) == .hasText else { return false }
            return centiseconds(earlierTime) == key
        }
        if duplicatedEarlier { issues.append(.duplicate) }

        let previousTimed = lines[..<index].last {
            $0.time != nil && isBlank($0.text) == .hasText
        }?.time
        if let previousTimed, time < previousTimed { issues.append(.reversed) }

        return issues
    }
}
