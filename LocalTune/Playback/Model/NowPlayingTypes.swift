import Foundation

/// 锁屏那件事的**词汇表**：给系统报的「播放速率」和两个键的可用性 —— **一次算全**。
///
/// 🔴 **为什么在 `Model/` 而不是 `Decisions/`**：判断（`Decisions/NowPlayingProjectionPolicy.swift`）
/// 产它，执行（`NowPlayingCenter.applyCommandAvailability`）消费它 —— **两边都用**
/// ⇒ 抽到最底 `Model/`。
///
/// 🔴 **为什么要打包成一个值**：给系统写这两样东西**都是一次跨进程调用**
/// ⇒ 要写就一次写全，别让「图态是新的、速率还是旧的」这种半截快照被系统读走。
/// ⚠️ 打包**不等于它们同源**：图态与速率用的是**两个判据**（见 `nowPlayingProjection`）。
struct NowPlayingProjection: Equatable {

    /// 给系统的**播放态**（按钮图态）。映射到 `MPNowPlayingPlaybackState` 在 `NowPlayingCenter`。
    /// 判据是**会话是否活跃**（装载也算在播），见 `nowPlayingProjection`。
    var playbackFace: NowPlayingPlaybackFace

    /// 给系统的**播放速率**。判据是**真的在出声吗**（装载中不算），见 `nowPlayingProjection`。
    ///
    /// 🔴 **`0` 就是「暂停」** —— 这是 iOS 认的信号：拿到 `0`，它就不再替我们把进度条往前走。
    /// 所以我们**不需要自己按秒去推进度**。
    var playbackRate: Float

    /// 锁屏上那个「播放」键亮不亮。
    var isPlayEnabled: Bool

    /// 「暂停」键亮不亮。
    var isPauseEnabled: Bool
}

/// 锁屏那块**现在是哪个态** —— 我们自己的词汇，映射到系统枚举的事归 `NowPlayingCenter`
/// （同 `RemoteRepeatFace` 的规矩：Model 只说自己的话，系统词汇不进来）。
///
/// 🔴 **为什么速率之外还要单独报一份**：速率管的是「进度条自己走不走」，
/// **按钮图态**是另一回事 —— 部分系统（iOS 16、自签安装）不会从速率倒推图态，
/// 于是暂停后按钮还停在「暂停」。我们为此**另报了一份**图态（`setPlaybackState:`，
/// 取 `rate > 0 ? 1 : 2`），这条私有调用由打包脚本里的
/// `com.apple.mediaremote.set-playback-state` entitlement 授权 —— 两半配套。
///
/// ⚠️ 它的判据是**会话是否活跃**（`PlayerState.isPlaybackActive`，含装载），
/// **不是**速率那条"真的在出声"—— 两个判据见 `nowPlayingProjection`。
enum NowPlayingPlaybackFace: Equatable {

    /// 用户眼里的「在播」—— **装载中那几百毫秒也算**（用户点了、引擎还没出声）。
    case playing

    /// 用户眼里的「没在播」：暂停 / 播完 / 没放成。
    case paused

    /// 什么都没装 —— 锁屏那块整个撤掉。
    case stopped
}
