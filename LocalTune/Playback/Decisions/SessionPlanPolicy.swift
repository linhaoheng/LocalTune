import AVFAudio

/// 「因为 X 来，会话该配成什么样」—— **纯函数**：不碰引擎、不碰界面，能单测。
///
/// 输入输出都是值类型（`AudioSessionReason` / `AudioSessionPlan`，在 `Playback/Model/`），
/// 本文件只放判断本身，不存状态。
func audioSessionPlan(for reason: AudioSessionReason) -> AudioSessionPlan {
    switch reason {
    case .willStartPlayback:
        // 用户点了播放就是要听 ⇒ **一律**配成「音乐播放」并激活。
        //
        // 🔴 这里**不看「别的 App 是不是在放」** —— 分岔就在这儿
        // （别的声音在放就跳过配置），
        // 后果是「同一个 App 从不同入口进来，会话行为不一样」，而且会「点了播放却没声」。
        // 用户按了播放键，就是要把声音拿过来 —— 该打断谁就打断谁。
        .activate(category: .playback, mode: .default)

    case .didStopPlayback:
        // 「真·不出声了」这一格 ⇒ **把输出还回去**。
        //
        // 🔴 不还的后果是听得见的：我们占着输出，别的 App 想出声得**先等系统把我们中断一遍**
        // —— 用户点开别的音乐 App，它恢复慢一拍。
        //
        // ⚠️ 这件事**不做任何判断**（不由"暂停了多久 / 用户还在不在看"决定）：
        // 「到没到这一格」—— 暂停放不放 —— 是下面 `audioSessionRelease(for:)` 的判断，
        // 调用方喂状态给它，由它决定走不走到这儿；一个判据只写一处。
        .deactivate
    }
}

/// 「现在这个状态，音频会话该不该还给系统」—— **纯函数**，能单测。
///
/// 🔴 判据一句话：**「暂停」不是「停播」**。
/// - `.stopped` / `.failed` / `.idle`：真·不出声了（播完 / 没放成 / 什么都没装）⇒ **还**；
/// - `.paused`：用户随时点继续 ⇒ **不还**。暂停的音乐 App 仍持有会话是系统常规
///   （锁屏控件、蓝牙键都靠会话活着）；还了 ⇒ 系统把引擎从背后停掉 ⇒ 库的「继续」无声失败
///   ⇒ 按钮显示在播、实际没声（装机实测的回归，就出在这儿）。
/// - `.playing` / `.loading`：正要出声 / 在出声 ⇒ 不还（正常流程里这两格走不到调用点，
///   列在这儿是穷举保护 —— `Status` 多一个态时这里当场编译不过）。
///
/// ⚠️ 它和 `PlayerState.isPlaybackActive` 是**两个判据、各管各的**：
/// 那个是**按钮图态**（在装也算在播），这个是**还不还会话**（暂停都算停播）—— 别互相替代。
func audioSessionRelease(for status: PlayerState.Status) -> AudioSessionRelease {
    switch status {
    case .stopped, .failed, .idle:
        return .release
    case .paused, .playing, .loading:
        return .keepActive
    }
}
