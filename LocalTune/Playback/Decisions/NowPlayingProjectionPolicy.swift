import Foundation

/// 「这一份状态，该给锁屏报什么？」—— 纯函数：值进、值出，
/// **不碰引擎、不碰 `MPNowPlayingInfoCenter`**，能在测试里不带系统跑一遍。
///
/// 吐的 `NowPlayingProjection` 在 `Playback/Model/NowPlayingTypes.swift` ——
/// 它**判断和执行都要用**（`NowPlayingCenter` 消费它），所以归最底的 `Model/`。
///
/// 🔴 **两个面，两个判据 —— 不许合成一个。**
/// - **按钮图态**（`playbackFace`）看 `isPlaybackActive`：**"用户认为在播吗"**。
///   装载也算在播 —— 用户刚点了这一首，那几百毫秒里他要看到"在播"；
///   按"没在播"报的话，换歌时会先闪一下播放键再跳回来（见 `PlayerState.isPlaybackActive`）。
/// - **速率**（`playbackRate`）看 `isPlaying`：**"现在真的在出声吗"**。
///   装载中还没出声 ⇒ 报 `0`，否则锁屏的进度条会从"文件还没打开"那一刻就开始往前走。
///
/// ⚠️ 这两件事**曾经挤在同一个判据里**，于是"进度条别走"的顾虑把按钮也拖下了水 ——
/// 换歌必闪。拆开之后两个判据各自归位。打包成一份**只**是为了
/// 「一次跨进程写」（`NowPlayingCenter` 一次写全，见 `NowPlayingProjection`），不是"同源"。
///
/// ⚠️ **`rate` 不是「暂停」，是变速**（`float(for: EffectsSession.rate)`）。
/// 暂停是**这儿算出来的 `0`**，不是传进来的 —— 传进来就等于同一个事实有两个来源，
/// 早晚出现「速率写着 1、其实已经停了」。
///
/// - Parameters:
///   - hasTrack: 现在装着一首歌吗。没有 ⇒ 两个键都不亮、速率 `0`（没东西可播）。
///   - isPlaybackActive: 会话是否活跃（`.playing` / `.loading`）。决定**按钮图态**。
///   - isPlaying: **真的在出声吗**（`PlayerState.Status.playing`）。决定**速率**。
///   - rate: 播放速率（变速用）。非法值（`0` / 负数 / `NaN` / `∞`）按 `1` 算。
func nowPlayingProjection(
    hasTrack: Bool,
    isPlaybackActive: Bool,
    isPlaying: Bool,
    rate: Float = 1
) -> NowPlayingProjection {
    guard hasTrack else {
        return NowPlayingProjection(
            playbackFace: .stopped,
            playbackRate: 0,
            isPlayEnabled: false,
            isPauseEnabled: false
        )
    }
    let safeRate = rate.isFinite && rate > 0 ? rate : 1
    return NowPlayingProjection(
        playbackFace: isPlaybackActive ? .playing : .paused,
        playbackRate: isPlaying ? safeRate : 0,
        isPlayEnabled: true,
        isPauseEnabled: true
    )
}
