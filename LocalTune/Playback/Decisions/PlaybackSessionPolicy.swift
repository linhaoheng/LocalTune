import Foundation

/// 续播秒数：非有限 / 负 ⇒ 0；有时长则夹住；不到门槛 ⇒ 0。
func playbackSessionResumePosition(
    raw: TimeInterval,
    duration: TimeInterval,
    threshold: TimeInterval
) -> TimeInterval {
    let unclamped = raw.isFinite ? max(0, raw) : 0
    let safeDuration = duration.isFinite ? max(0, duration) : 0
    let clamped = safeDuration > 0 ? min(unclamped, safeDuration) : unclamped
    return clamped > threshold ? clamped : 0
}

/// 把活状态收成冷快照。没当前曲 / 队列空 / 游标越界 ⇒ `nil`（调用方决定清档还是跳过）。
///
/// 🔴 **纯变换**：吃值、吐值 —— 不碰 `PlayManager`、不碰队列对象、不碰磁盘。
/// `updatedAt` 的「现在」由调用方给：**现读时钟本身就是副作用**，纯函数里不读
/// （执行方 `PlayManager.persistSession` 传 `Date()`）。
///
/// ⚠️ 三个前置条件在这儿**再判一遍**（不只信调用方）—— 它们决定的是「这份快照能不能用」，
/// 混进 `PlayerState` 里判就等于把这一层的规矩摊到调用点。
func playbackSessionSnapshot(
    hasCurrentTrack: Bool,
    capture: PlaybackQueueCapture,
    playbackMode: PlaybackMode,
    isPlaying: Bool,
    position: TimeInterval,
    now: Date
) -> PlaybackSessionSnapshot? {
    guard hasCurrentTrack, !capture.trackIDs.isEmpty else { return nil }
    guard capture.trackIDs.indices.contains(capture.currentIndex) else { return nil }

    return PlaybackSessionSnapshot(
        version: PlaybackSessionSnapshot.currentVersion,
        trackIDs: capture.trackIDs,
        originalIDs: capture.originalIDs,
        upNextIDs: capture.upNextIDs,
        currentIndex: capture.currentIndex,
        position: position,
        playbackMode: playbackMode,
        wasPlaying: isPlaying,
        updatedAt: now
    )
}

/// 对照库里还在的 id，把快照收成可恢复计划。不行就 `nil`（**禁止**整库顶上）。
func playbackSessionRestorationPlan(
    snapshot: PlaybackSessionSnapshot,
    availableIDs: Set<String>
) -> PlaybackSessionRestorationPlan? {
    guard snapshot.version == PlaybackSessionSnapshot.currentVersion else { return nil }
    guard !snapshot.trackIDs.isEmpty else { return nil }
    guard snapshot.trackIDs.indices.contains(snapshot.currentIndex) else { return nil }
    let currentID = snapshot.trackIDs[snapshot.currentIndex]
    guard availableIDs.contains(currentID) else { return nil }

    var oldToNew: [Int: Int] = [:]
    var restoredTracks: [String] = []
    restoredTracks.reserveCapacity(snapshot.trackIDs.count)
    for (oldIndex, id) in snapshot.trackIDs.enumerated() where availableIDs.contains(id) {
        oldToNew[oldIndex] = restoredTracks.count
        restoredTracks.append(id)
    }
    guard let restoredIndex = oldToNew[snapshot.currentIndex], !restoredTracks.isEmpty else {
        return nil
    }

    let restoredOriginal = snapshot.originalIDs.filter(availableIDs.contains)
    let restoredUpNext = snapshot.upNextIDs.filter(availableIDs.contains)
    // 时长未知时不做上界夹取；门槛仍生效。
    let position = playbackSessionResumePosition(
        raw: snapshot.position,
        duration: 0,
        threshold: AppMetrics.playbackSessionMeaningfulResume
    )

    return PlaybackSessionRestorationPlan(
        trackIDs: restoredTracks,
        originalIDs: restoredOriginal.isEmpty ? restoredTracks : restoredOriginal,
        upNextIDs: restoredUpNext,
        currentIndex: restoredIndex,
        position: position,
        playbackMode: snapshot.playbackMode,
        shouldStartPlayback: false
    )
}
