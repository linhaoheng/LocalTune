import Foundation

/// 某一行在**海报自己的时间线**上被唱到的时段（零点 = 导出的第一帧）。
struct LyricsPosterMotionWindow: Hashable {
    let lineID: String
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval { max(end - start, 0) }

    func progress(at time: TimeInterval) -> Double {
        guard duration > 0 else { return time >= start ? 1 : 0 }
        return min(max((time - start) / duration, 0), 1)
    }
}

/// 一张动态海报的时间线：一共多长、静帧取第几帧、哪一句在什么时候亮。
struct LyricsPosterMotionPlan: Hashable {
    let duration: TimeInterval
    let frameRate: Int
    let windows: [LyricsPosterMotionWindow]
    /// 实况照片不播时显示的那一帧。落在"整段都亮起来"的那一刻，静图跟动图才对得上。
    let stillFrameIndex: Int

    var frameCount: Int {
        max(1, Int((duration * Double(frameRate)).rounded()))
    }

    func time(ofFrame index: Int) -> TimeInterval {
        guard frameRate > 0 else { return 0 }
        return Double(index) / Double(frameRate)
    }

    var stillFrameTime: TimeInterval { time(ofFrame: stillFrameIndex) }

    /// 某一行的呈现进度，0…1。已经唱过的行恒为 1。
    func reveal(ofLineAt index: Int, at time: TimeInterval) -> Double {
        guard windows.indices.contains(index) else { return 1 }
        return windows[index].progress(at: time)
    }
}

/// 用选中的那一段搭一条实况照片长度的时间线。
///
/// 每次都**重搭**、不复用播放的时间：选段可能横跨歌里的一分钟，而导出的动态必须短到
/// iOS 还认它是可配对的实况照片。
enum LyricsPosterMotionPolicy {

    /// iOS 大约播三秒动态；更长的配对视频也收，但尾巴永远看不到，所以停在真能播完的范围里。
    static let minimumDuration: TimeInterval = 2.4
    static let maximumDuration: TimeInterval = 5.6
    /// 第一行出现之前的静场。
    static let leadIn: TimeInterval = 0.28
    /// 最后一行唱完之后留的尾巴，够把整段读完。
    static let tail: TimeInterval = 0.9

    static func plan(
        for content: LyricsPosterContent,
        frameRate: Int = LyricsPosterMetrics.exportFrameRate
    ) -> LyricsPosterMotionPlan {
        let rate = max(frameRate, 1)
        guard !content.lines.isEmpty else {
            return LyricsPosterMotionPlan(
                duration: minimumDuration,
                frameRate: rate,
                windows: [],
                stillFrameIndex: 0
            )
        }

        let spans = content.isSynchronized
            ? synchronizedSpans(of: content)
            : evenSpans(of: content)
        let body = spans.last?.end ?? 0
        let rawDuration = leadIn + body + tail
        let duration = min(max(rawDuration, minimumDuration), maximumDuration)
        // 段落长时**压缩**而不是截断：每一行都还得在导出的片段里露一次脸。
        let usableBody = max(duration - leadIn - tail, 0.2)
        let scale = body > 0 ? min(1, usableBody / body) : 1

        let windows = zip(content.lines, spans).map { line, span in
            LyricsPosterMotionWindow(
                lineID: line.id,
                start: leadIn + span.start * scale,
                end: leadIn + span.end * scale
            )
        }

        let revealed = windows.last?.end ?? duration
        // 静帧停在最后一行落位之后一拍，并夹在片段之内，配对静图才一定找得到对应的那一帧。
        let stillTime = min(revealed + 0.25, max(duration - 1.0 / Double(rate), 0))
        let stillFrameIndex = max(0, Int((stillTime * Double(rate)).rounded()))

        return LyricsPosterMotionPlan(
            duration: duration,
            frameRate: rate,
            windows: windows,
            stillFrameIndex: stillFrameIndex
        )
    }

    private struct Span {
        let start: TimeInterval
        let end: TimeInterval
    }

    /// 取歌里的相对节奏，但每一行的停留时间都夹一道 —— 两句之间的一段长间奏不该吃掉整个片段。
    private static func synchronizedSpans(of content: LyricsPosterContent) -> [Span] {
        let lines = content.lines
        var spans: [Span] = []
        var cursor: TimeInterval = 0
        for (index, line) in lines.enumerated() {
            let nextStart = index + 1 < lines.count ? lines[index + 1].timestamp : nil
            let sungEnd = line.endTimestamp ?? nextStart ?? (line.timestamp + 2.4)
            let rawDwell = max(sungEnd - line.timestamp, 0.35)
            let dwell = min(rawDwell, 2.6)
            let rawGap = (nextStart ?? sungEnd) - sungEnd
            let gap = min(max(rawGap, 0), 0.6)
            spans.append(Span(start: cursor, end: cursor + dwell))
            cursor += dwell + gap
        }
        return spans
    }

    private static func evenSpans(of content: LyricsPosterContent) -> [Span] {
        let count = content.lines.count
        let dwell: TimeInterval = count <= 2 ? 1.4 : count <= 4 ? 1.0 : 0.7
        return (0..<count).map { index in
            Span(start: Double(index) * dwell, end: Double(index) * dwell + dwell)
        }
    }
}
