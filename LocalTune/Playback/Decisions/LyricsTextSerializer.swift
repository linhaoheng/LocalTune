import Foundation

/// `[LyricsLine]` → 文本。**唯一的写出口**（一个语法一个写口，不是每种格式各写一套）。
///
/// 有写口的只有两种语法（`LyricsSyntax.hasWriter`）：
///
/// - `.lrc` → `serializeLRC`：行头 `[mm:ss.mmm]` ＋ 行内 `<mm:ss.mmm>字`；**行末那一块看数据形态** ——
///   数组里带句尾格（`isLineEnd`）就照写，不带（KRC 布局读进来的行）才按末字的结束补；
/// - `.krcLayout` → `serializeKRCLayout`：行头 `[行起,行长]` ＋ `<字相对起,字长,0>字`。
///
/// 其余语法（`yrc` / `qrc` / `lys` / `vtt` / `srt` / `ttml`）**没有写口**：它们进编辑页只读，
/// 保存时原文原样写回（§6.3）。`serialize(_:as:)` 对它们返回 `nil` —— 调用方拿到 `nil`
/// 就**不要改写原文**，不许退回另一种语法去写（那等于替用户换了格式）。
///
/// ⚠️ **粒度是毫秒**（`mm:ss.mmm`，照 primuse `formatTimestamp`）：时间轴内部就是
/// 毫秒精度 —— KRC 布局的字长是毫秒、平移那一步也量化到毫秒（`LyricDocumentOffsetPolicy`）。
/// 写成厘秒等于在出口把数据砍掉一档：KRC 布局 → LRC 转一次就丢 3 毫秒，谁都看不出来。
///
/// ⚠️ **KRC 布局写不了就不写**（不回落）：没打轴的行、正文里带 `<` / `>`、带译文的，
/// 调用方先用 `krcLayoutIssue` 问一句；有问题就**不重写原文**，提示用户先补轴/删行。
enum LyricsTextSerializer {

    /// KRC 布局写不了的原因（带行号，供提示用）。
    enum KRCLayoutIssue: Equatable {
        case untimed(Int)
        case markup(Int)
        case translation(Int)
    }

    // MARK: - 选择

    /// 按语法写回原文；**这种语法没有写口就返回 `nil`**。
    static func serialize(_ lines: [LyricsLine], as syntax: LyricsSyntax) -> String? {
        switch syntax {
        case .lrc:
            return serializeLRC(lines)
        case .krcLayout:
            return serializeKRCLayout(lines)
        case .yrc, .qrc, .lys, .vtt, .srt, .ttml:
            return nil
        }
    }

    /// 这份歌词能不能无损写成 KRC 布局。
    static func canSerializeKRCLayout(_ lines: [LyricsLine]) -> Bool {
        krcLayoutIssue(in: lines) == nil
    }

    /// 第一处写不了 KRC 布局的地方；`nil` ＝ 能写。
    static func krcLayoutIssue(in lines: [LyricsLine]) -> KRCLayoutIssue? {
        for (index, line) in lines.enumerated() {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard line.isSynchronized else { return .untimed(index) }
            if text.contains("<") || text.contains(">") { return .markup(index) }
            if line.manualTranslation != nil || !line.alternateTranslations.isEmpty {
                return .translation(index)
            }
        }
        return nil
    }

    // MARK: - KRC 布局

    static func serializeKRCLayout(_ lines: [LyricsLine]) -> String {
        var output: [String] = []
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let startMs = Int((max(0, line.timestamp) * TimeUnit.millisecondsPerSecond).rounded())
            // 🔴 行尾取**最后一个字**的结束，不是 `syllables.last.end` ——
            // 末项是句尾那一格，它的 `end == start`，拿来当行长会变成 0。
            let end = line.endTimestamp ?? line.lastWord?.end ?? line.timestamp
            let durationMs = max(
                0,
                Int(((max(end, line.timestamp) - line.timestamp) * TimeUnit.millisecondsPerSecond).rounded())
            )
            var serialized = "[\(startMs),\(durationMs)]"

            if let syllables = line.syllables, !syllables.isEmpty {
                // 每个字自带"字长"，没有句尾那一格的位置 —— 跳过它（`text` 空，
                // 写出去只会是个零长空字）。句尾时间走上面的行长。
                for syllable in syllables where !syllable.isLineEnd {
                    let relative = max(
                        0,
                        Int(((syllable.start - line.timestamp) * TimeUnit.millisecondsPerSecond).rounded())
                    )
                    let wordDuration = max(
                        0,
                        Int(((syllable.end - syllable.start) * TimeUnit.millisecondsPerSecond).rounded())
                    )
                    serialized += "<\(relative),\(wordDuration),0>\(syllable.text)"
                }
            } else {
                serialized += text
            }
            output.append(serialized)
        }
        return output.joined(separator: "\n")
    }

    // MARK: - LRC（行级／字级同一套）

    static func serializeLRC(_ lines: [LyricsLine]) -> String {
        var output: [String] = []
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let head = line.isSynchronized ? "[\(lrcTime(line.timestamp))]" : ""
            if let syllables = line.syllables, !syllables.isEmpty {
                // 每个标记只写"起点"：一个词唱到哪结束，全靠**下一个标记**说。
                var body = syllables
                    .map { "<\(lrcTime($0.start))>\($0.text)" }
                    .joined()
                // 行尾那一块，**两种数据形态各有各的写法**：
                //
                // ① **带句尾格**（数组末项 `isLineEnd`，LRC 读进来的行）：
                //    它自己就是 `<mm:ss.mmm>`，上面那句 `map` 已经把它写出来了，这里不动。
                // ② **不带句尾格**（KRC 布局读进来的行：字自带"字长"，句尾藏在末字的 `end` 里）：
                //    末字后面没有下一个标记，得把它的结束补成空块，否则读回来只剩零长。
                //    ⚠️ 只补**源档给的**结束（`.explicit`）；推出来的那个补上去，
                //    等于替源档编一个它没说过的时间。
                if let last = syllables.last,
                   !last.isLineEnd,
                   last.endTiming == .explicit,
                   last.end >= last.start {
                    body += "<\(lrcTime(last.end))>"
                }
                output.append(head + body)
            } else {
                output.append(head + text)
            }
            // 双语：同一时间戳的下一行；解析器会配回去。
            for companion in line.companionTexts {
                output.append(head + companion)
            }
        }
        return output.joined(separator: "\n")
    }

    // MARK: - 小工具

    /// 秒 → `mm:ss.mmm`（毫秒）。
    ///
    /// ⚠️ **整数毫秒算、不在浮点上取三位**：直接 `%06.3f` 打 `seconds` 的话，
    /// `59.9996` 会印成 `00:60.000` —— 那不是合法的时间戳（分钟那格该进位），
    /// 而且进位与否取决于浮点尾数，肉眼看不出来。先取整到毫秒再拆分钟/秒，
    /// 进位就自然发生在整数里（跟 primuse `formatTimestamp` 一模一样）。
    private static func lrcTime(_ time: TimeInterval) -> String {
        let milliseconds = Int(max(0, (time * 1_000).rounded()))
        let minutes = milliseconds / 60_000
        let seconds = (milliseconds % 60_000) / 1_000
        let fraction = milliseconds % 1_000
        return String(format: "%02d:%02d.%03d", minutes, seconds, fraction)
    }
}
