import Foundation

/// 「编辑歌词」页的**纯判断** —— 格式化 / 问题检测。
///
/// 解析、导出、打轴动作已经搬到「原文是真相」那套：
/// - 读：`LyricsParser`（走探测链：LRC 族 ＋ KRC 布局）；
/// - 写：`LyricsTextSerializer`；
/// - 打轴/平移：`LyricsEditorViewModel`（在窗口副本上做）。
///
/// 这里只留页面还要用的：时间格式化、每行问题、保存前问题清单、未打轴计数。
/// 不 import UIKit，能脱离页面单测。
enum LyricsEditorPolicy {

    /// 保存前的问题清单**最多列几条**。
    static let saveIssueLimit = 4

    /// 秒 → `mm:ss.xx`。
    ///
    /// 🔴 格式是 `String(format: "%02d:%05.2f", minutes, seconds)`：
    /// 负数夹到 0；这是全编辑器（含 `LyricsSyllableTimingPolicy` 的标签生成）的**唯一**写法。
    static func format(_ time: TimeInterval) -> String {
        let clamped = max(0, time)
        let minutes = Int(clamped) / 60
        let seconds = clamped - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, seconds)
    }

    /// 打轴页中间格等处的占位：没打轴画 `--:--`（保高度；空串会把栈挤扁）。
    static func timeButtonTitle(for time: TimeInterval?) -> String {
        guard let time else { return "--:--" }
        return format(time)
    }

    /// 逐行页时间键：还没打轴时面上的字。
    static let unstampedLineTimeButtonTitle = "打点"

    // MARK: - 问题检测

    /// 时间 → **厘秒**。时间比较一律先量化。
    ///
    /// 🔴 `Int((time * 100).rounded())`：`1.0004` 和 `1.0001` 是同一时刻，
    /// 直接比 `Double` 会漏掉这处重复。
    static func centiseconds(_ time: TimeInterval) -> Int {
        Int((time * 100).rounded())
    }

    /// 这一行是不是空行（全空白）。
    static func isBlank(_ text: String) -> LyricsLineBlankness {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .blank : .hasText
    }

    /// **每一行**的问题 —— 返回值与 `lines` 一一对应、同长。
    static func rowIssues(in lines: [LyricsEditorLine]) -> [[LyricIssueKind]] {
        lines.indices.map { rowIssues(at: $0, in: lines) }
    }

    /// 保存前那串确认文案：每条 `N行，问题`，最多 `saveIssueLimit` 条。
    ///
    /// 空行不算（跳过），所以只会出现 未打轴 / 时间重复 / 时间倒序。
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

    /// 这一趟"未打轴"的行有几行（含空行）。
    static func untimedCount(in lines: [LyricsEditorLine]) -> Int {
        lines.filter { $0.time == nil }.count
    }

    // MARK: - 原文级问题（解析时被丢掉的坏行）

    /// 原文里"看着像歌词、却读不出行"的地方。
    ///
    /// 🔴 **必须单独报**：这些行在解析时就被丢掉了，工作副本里根本没有它们 ——
    /// `rowIssues` 是按工作副本逐行算的，报不出"消失的行"。不在这儿说一句，
    /// 用户只会看到"行数少了"，却不知道是哪一行坏、为什么坏（§6.1 定案：打开时只报问题、
    /// 不改写原文）。
    struct SourceIssue: Equatable {

        enum Kind: Equatable {
            /// 有时间戳的形状，但整行读不出来（坏时间戳 / 坏字标记）。
            case invalidTimestamp
            /// 有时间戳、但正文是空的。
            case emptyTimedLine
            /// 时间比上一行还早。
            case nonMonotonicTimestamp

            var label: String {
                switch self {
                case .invalidTimestamp: return "时间戳读不出来，这一行没法显示"
                case .emptyTimedLine: return "有时间戳但没有正文"
                case .nonMonotonicTimestamp: return "时间比上一行早"
                }
            }
        }

        /// 原文里的行号（从 1 起，与编辑器里看到的一致）。
        let lineNumber: Int
        let kind: Kind
    }

    /// 文件头 `[ti:]` `[ar:]` … —— 它们不是 lyrics，报问题时要跳过。
    private static let metadataLinePattern = #/^\s*\[[A-Za-z][A-Za-z0-9_-]*:.*\]\s*$/#

    /// 时间戳形状的行头（`[mm:ss` 或 `[起,长`）—— 只用来判"这一行本来该有时间"。
    private static let timedHeadPattern = #/^\s*\[(\d+)[:,]\d+/#

    /// 原文里的问题清单。
    ///
    /// 做法照 primuse `LyricsContentParser.validateEditableText`：**在原文上逐行重解析**
    /// （不是拿工作副本反推），因为坏行只在原文里还活着。
    ///
    /// 只查"该有时间的行"：没有时间戳的纯文本行本来就合法，不能算坏。
    static func sourceIssues(in text: String) -> [SourceIssue] {
        var issues: [SourceIssue] = []
        var previousTimestamp: TimeInterval?

        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.firstMatch(of: metadataLinePattern) == nil else { continue }

            let looksTimed = trimmed.firstMatch(of: timedHeadPattern) != nil
            // 行内字标记（`<…>`）也算"该读得出来"：一份逐字行读空了是坏，不是纯文本。
            let carriesWordMarkers = trimmed.contains("<") && trimmed.contains(">")
            guard looksTimed || carriesWordMarkers else { continue }

            let parsed = LyricsParser.parse(raw)
            // 🔴 只认**有时间轴**的那些行：我们的门面是"读不出时间戳就回落纯文本"，
            // 所以坏时间戳的行会被读成一行 `isSynchronized == false` 的正文 ——
            // 拿 `parsed.isEmpty` 判，这种行永远报不出来。
            let timedLines = parsed.filter(\.isSynchronized)
            if looksTimed, timedLines.isEmpty {
                issues.append(SourceIssue(lineNumber: offset + 1, kind: .invalidTimestamp))
                continue
            }
            guard !timedLines.isEmpty else { continue }
            if looksTimed,
               timedLines.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
                issues.append(SourceIssue(lineNumber: offset + 1, kind: .emptyTimedLine))
            }
            for line in timedLines {
                if let syllables = line.syllables,
                   zip(syllables, syllables.dropFirst()).contains(where: { $0.start > $1.start }) {
                    issues.append(
                        SourceIssue(lineNumber: offset + 1, kind: .nonMonotonicTimestamp)
                    )
                }
                if let previousTimestamp, line.timestamp < previousTimestamp {
                    issues.append(
                        SourceIssue(lineNumber: offset + 1, kind: .nonMonotonicTimestamp)
                    )
                    break
                }
                previousTimestamp = line.timestamp
            }
        }
        return issues
    }

    // MARK: - 私有

    private static func rowIssues(
        at index: Int,
        in lines: [LyricsEditorLine]
    ) -> [LyricIssueKind] {
        let line = lines[index]
        guard isBlank(line.text) == .hasText else { return [.empty] }
        guard let time = line.time else { return [.untimed] }

        var issues: [LyricIssueKind] = []
        let key = centiseconds(time)

        let duplicatedEarlier = lines[..<index].contains { earlier in
            guard let earlierTime = earlier.time, isBlank(earlier.text) == .hasText else {
                return false
            }
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
