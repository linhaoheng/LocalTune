import Foundation

/// 文档级 `[offset:±毫秒]` —— **唯一的出处**。
///
/// `.lrc` / `.elrc` 手工校时用这个头，KRC 明文里也带（酷狗头部常见 `[offset:0]`）。
/// 它必须真的进时间轴，不能只躺在文件头里：以前 LRC 族认它、KRC 布局不认，
/// 同一份歌换个来源轴就差几百毫秒，谁都看不出来。
///
/// 照 primuse `LyricDocumentOffsetPolicy`（`LyricLine.swift`）。
enum LyricDocumentOffsetPolicy {

    /// 超过这个幅度多半不是"有意校正"而是标签坏了 —— 整份不动（照 primuse）。
    static let maximumMagnitude: TimeInterval = 600

    /// 文件头里的 offset，**秒**。没有／读不出／超幅 ⇒ `nil`。
    ///
    /// 倒着找：后写的那个头赢（照 primuse）。
    static func offsetSeconds(in metadataLines: [String]) -> TimeInterval? {
        for line in metadataLines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { continue }
            let body = trimmed.dropFirst().dropLast()
            guard let separator = body.firstIndex(of: ":"),
                  body[..<separator].trimmingCharacters(in: .whitespaces).lowercased() == "offset"
            else { continue }

            var value = body[body.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("+") { value.removeFirst() }
            guard let milliseconds = Double(value), milliseconds.isFinite else { continue }

            let seconds = milliseconds / 1_000
            guard seconds != 0, abs(seconds) <= maximumMagnitude else { return nil }
            return seconds
        }
        return nil
    }

    /// 正数 = 歌词**提前**显示（跟 OpenSubsonic 的 track offset 同向），所以是**减**。
    ///
    /// 到 0 处夹紧；毫秒取整，免得浮点误差越滚越大。
    ///
    /// 🔴 **行尾（`endTimestamp`）一起移**：它是 KRC 布局的「行长」换成秒存下来的，
    /// 只移行头不移行尾，行长就会凭空变长或变短一个 offset —— 写回 KRC 布局时那行会被拉长。
    static func applying(offset: TimeInterval, to lines: [LyricsLine]) -> [LyricsLine] {
        guard offset != 0, offset.isFinite else { return lines }
        return lines.map { line in
            var shifted = line
            shifted.timestamp = moved(line.timestamp, by: offset)
            shifted.endTimestamp = line.endTimestamp.map { moved($0, by: offset) }
            shifted.syllables = line.syllables?.map { syllable in
                var movedSyllable = syllable
                movedSyllable.start = moved(syllable.start, by: offset)
                movedSyllable.end = moved(syllable.end, by: offset)
                return movedSyllable
            }
            return shifted
        }
    }

    /// 毫秒量化 —— 平移后的值要能原样印成 LRC 时间戳，不是一串二进制小数。
    private static func moved(_ time: TimeInterval, by offset: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return time }
        return max(0, ((time - offset) * 1_000).rounded() / 1_000)
    }
}
