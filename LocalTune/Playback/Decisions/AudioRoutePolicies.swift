import Foundation

/// 系统换了音频出口时「该干什么」—— **纯函数**：几个值进、一个 enum 出，不带引擎能单测。
///
/// 判据取自 primuse 的三条政策（`NowPlayingPlaybackProjection.swift` 里的
/// `AudioOutputRouteLossPolicy` / `BluetoothPlaybackRecoveryPolicy` /
/// `AirPlayReturnFocusRecoveryPolicy`），按我们骨架裁到最小。三条要点：
///
/// - **顺序钉在这一处**：先 AirPlay 重抢 → 再外接丢失暂停 → 再蓝牙延期续播，执行层不再自己排；
/// - 外接丢失要**三条件全真**才暂停 —— 挡住 iOS 在仍挂内建扬声器时发的假 `.oldDeviceUnavailable`；
/// - 蓝牙延期续播**一次性**：不跨曲、不跨用户意图。
///
/// 🔴 **公开出口只有一个、且返回 enum**。下面三个判据是**私有**的，
/// 与 primuse 同参同语义；它们返回 `Bool` 不算破线 —— 破线的是「判断层对外暴露的出口」，
/// 私有实现步骤不是。
///
/// - Parameters:
///   - facts: 这次变更的事实（旧 / 新出口 ＋ reason）。**不**在这里读会话对象。
///   - playbackIsIntended: 用户**还想不想听** —— 在播 / 在装，或欠一次打断恢复，或手里压着
///     HFP 续播票。⚠️ 与「现在在不在响」是两件事。
///   - isAwaitingInterruptionEnd: 打断那趟还没收尾（打断票未销）。
///   - isPlaybackActuallyActive: 现在真的在出声（在播 / 在装）。
///   - suspendedTrackID: HFP 续播票上钉的那首歌；`nil` ＝ 没票。
///   - currentTrackID: 现在装着的歌。
/// - Returns: 该做的**一件事**；`wait` 由执行层原样留着票。
func audioRouteChangeAction(
    facts: AudioRouteChangeFacts,
    playbackIsIntended: Bool,
    isAwaitingInterruptionEnd: Bool,
    isPlaybackActuallyActive: Bool,
    suspendedTrackID: Track.ID?,
    currentTrackID: Track.ID?
) -> AudioRouteChangeAction {
    if shouldReacquireAfterAirPlayReturn(
        facts: facts,
        playbackIsIntended: playbackIsIntended,
        isAwaitingInterruptionEnd: isAwaitingInterruptionEnd,
        isPlaybackActuallyActive: isPlaybackActuallyActive
    ) {
        return .reacquireAfterAirPlay
    }
    if shouldPauseForExternalOutputLoss(facts: facts) {
        return .pauseForExternalLoss
    }
    if suspendedTrackID != nil {
        return .bluetoothDeferred(
            bluetoothDeferredResumeDecision(
                facts: facts,
                playbackIsIntended: playbackIsIntended,
                isAwaitingInterruptionEnd: isAwaitingInterruptionEnd,
                isPlaybackActuallyActive: isPlaybackActuallyActive,
                suspendedTrackID: suspendedTrackID,
                currentTrackID: currentTrackID
            )
        )
    }
    return .none
}

// MARK: - 私有判据（与 primuse 同参同语义）

/// 外接**真**丢了才暂停：reason 是「设备走了」**且** 旧路由有外接 **且** 新路由没有。
///
/// 🔴 **三个条件缺一不可**：只看 reason 的话，iOS 在仍挂内建扬声器时发的那条假通知
/// 会把正在放的歌误暂停 —— 这就是「抄 primuse、不抄参考实现」的地方。
private func shouldPauseForExternalOutputLoss(facts: AudioRouteChangeFacts) -> Bool {
    facts.reasonIsOldDeviceUnavailable
        && facts.previousOutputs.contains(where: isExternalOutput)
        && !facts.currentOutputs.contains(where: isExternalOutput)
}

/// AirPlay 播着播着回到本机 ⇒ 重抢本地会话焦点。
///
/// 会话激活没变过时 iOS 不会重跑非混音仲裁，别人可能还占着喇叭 / 听筒。只对
/// 「本来就在放、还想听、不欠打断收尾、且不是物理拔线那种」这一次转场做。
///
/// ⚠️ 「支持本地管线恢复」在我们这儿**恒真**（本地曲库，没有 Cast / Apple Music / 直播）——
/// 所以这一条不进参数，写死在判据里。
private func shouldReacquireAfterAirPlayReturn(
    facts: AudioRouteChangeFacts,
    playbackIsIntended: Bool,
    isAwaitingInterruptionEnd: Bool,
    isPlaybackActuallyActive: Bool
) -> Bool {
    facts.previousOutputs.contains(.airPlay)
        && facts.currentOutputs.contains(.builtIn)
        && !facts.reasonIsOldDeviceUnavailable
        && isPlaybackActuallyActive
        && playbackIsIntended
        && !isAwaitingInterruptionEnd
}

/// 蓝牙从通话档回到能放的档之后，续不续那张一次性的票。
///
/// 一次性的含义：**不跨曲、不跨用户意图** —— 票主不是当前曲、或用户已经不想听了，
/// 就作废（`.discard`），绝不在扬声器上偷偷响起来。
///
/// ⚠️ 「支持自动恢复」同样**恒真**（本地曲库，没有 Cast / Apple Music / 直播）。
private func bluetoothDeferredResumeDecision(
    facts: AudioRouteChangeFacts,
    playbackIsIntended: Bool,
    isAwaitingInterruptionEnd: Bool,
    isPlaybackActuallyActive: Bool,
    suspendedTrackID: Track.ID?,
    currentTrackID: Track.ID?
) -> BluetoothDeferredResumeDecision {
    guard suspendedTrackID != nil else { return .discard }
    // 还在通话档 / 还没回到蓝牙 / 打断那趟没收尾 ⇒ 再等等，票留着。
    guard !facts.currentOutputs.contains(.bluetoothHFP),
          facts.currentOutputs.contains(where: isBluetooth),
          !isAwaitingInterruptionEnd else {
        return .wait
    }
    guard playbackIsIntended,
          !isPlaybackActuallyActive,
          suspendedTrackID == currentTrackID else {
        return .discard
    }
    return .resume
}

// MARK: - 口分类

/// 是不是**外接**口 —— 扬声器 / 听筒以外的都算（有线 / 蓝牙 / AirPlay / 车机 / USB……）。
private func isExternalOutput(_ kind: AudioRoutePortKind) -> Bool {
    kind != .builtIn
}

/// 是不是蓝牙（任意 profile）。
private func isBluetooth(_ kind: AudioRoutePortKind) -> Bool {
    kind == .bluetoothA2DP || kind == .bluetoothHFP || kind == .bluetoothLE
}
