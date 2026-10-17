import Foundation

/// 播放次数：一首歌这一趟**真实听满**阈值，就记一次 +1。
///
/// 🔴 从 `PlayManager` 拆出来的理由：它管的是**统计**，不是"放哪首"——
/// 它有自己的一套状态（下面四个字段），总管别的代码一个都不碰；总管只在两处告诉它：
/// 「新的一趟开始了」（`beginPlay`）和「进度读数来了」（`noteListening`）。
///
/// **判断在 `Decisions/PlayCountPolicy.swift`**（这一拍算不算听过、满没满），这里只管
/// 持有累计状态、照着结果改字段、写库。写库的那一下由装配层注入 —— 它不认识 `LibraryStore`。
///
/// 「显示播放次数」开关关着也照记 —— 开关只管列表画不画（`AppSettings`）。
///
/// **全在主线程**：两个入口都由 `PlayManager` 在主线程上叫。
@MainActor
final class PlayCountTracker {

    /// 听满阈值后把「这首 +1」写回库。
    private let recordPlay: (Track.ID) throws -> Void

    /// 这一趟在给哪首歌累计听时。
    private var trackID: Track.ID?

    /// 这一趟已经记过一次了 —— 同一首歌连听再久也不再 +1，直到下一趟。
    private var counted = false

    /// 这一趟**真实听过**的秒数（暂停不加、拖进度的大跳不算）。
    private var listenedSeconds: TimeInterval = 0

    /// 上一次进度读数 —— 用来算「这一拍听了多少」；`nil` ＝ 还没采过样。
    private var lastSample: TimeInterval?

    init(recordPlay: @escaping (Track.ID) throws -> Void) {
        self.recordPlay = recordPlay
    }

    /// 新的一趟开始了（点播一首 / 无缝接上下一首 / 单曲循环又从头来）—— 累计从零开始。
    func beginPlay(of trackID: Track.ID) {
        self.trackID = trackID
        counted = false
        listenedSeconds = 0
        lastSample = nil
    }

    /// 进度读数来了 → 问纯函数这一拍该不该累计 / 记次，再动手。
    ///
    /// - Parameters:
    ///   - position: 这一拍的进度（秒）。
    ///   - isPlaying: 现在是不是真的在播（暂停不算听）。
    ///   - playingTrackID: 现在装着的那首 —— 跟这一趟的对不上就不算。
    func noteListening(at position: TimeInterval, isPlaying: Bool, playingTrackID: Track.ID?) {
        let tick = playCountTick(
            position: position,
            isPlaying: isPlaying,
            trackMatches: playingTrackID == trackID,
            alreadyCounted: counted,
            listenedSeconds: listenedSeconds,
            lastSample: lastSample
        )
        switch tick {
        case .ignore:
            return
        case .accumulate(let listened, let sample):
            listenedSeconds = listened
            lastSample = sample
        case .thresholdReached(let listened, let sample):
            listenedSeconds = listened
            lastSample = sample
            guard let trackID else { return }
            do {
                try recordPlay(trackID)
            } catch {
                // 敢吞：本趟这一次丢了；钉住 counted，避免阈值后每拍（约 10Hz）反复刷库。
                // 下一趟会重新累计。本地库写失败本身极罕见（磁盘满 / 库坏）。
            }
            counted = true
        }
    }
}
