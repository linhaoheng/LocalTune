import Foundation

/// 🔴 「装的是哪一首、播到哪一步了」的**唯一真相** —— 全工程只有这一个类型能回答这两件事。
///
/// **谁写谁读**：只有 `PlayManager` 写它；迷你条 / 播放页 / 锁屏**各订阅一份、谁也不存**
/// 多存一份就是"同一个事实有两个人记着"，
/// 迟早出现"条子上在播、播放页停在暂停"。
///
/// 🔴 **这条线不因为加功能而松**：以后不管多出多少订阅方（投屏 / Watch / CarPlay / 小组件），
/// 谁要"现在在播什么"都**只能订阅这一份**，**不许自己再存一个** `var currentTrack` 之类的字段。
/// 新界面只是**多一个订阅方** —— 这个文件和 `PlayManager` 一个字都不用改。
///
/// ⚠️ **进度不在这里。** 它 10Hz 变一次，混进来的话每个订阅总状态的界面每秒要重算十几次
/// （一个曲目列表就是每秒十几次「过滤 + 排序 + 建行」）。所以它是**单独一条流**
/// —— `PlayManager.position`，只给真的关心进度的订阅方（锁屏、迷你条顶上那条、播放页滑杆）。
///
/// ⚠️ **还没到那一步的字段不放进来** —— 速率 / EQ 至今没有消费方
/// 播放走法见 `playbackMode`（互斥四档）。
struct PlayerState: Equatable {

    /// 装的是哪一首；`nil` ＝ 什么都没装（App 刚起来、还没点过歌）。
    var track: Track?

    var status: Status

    /// 时长（秒）—— **引擎报的那个**。
    ///
    /// ⚠️ 它和库里记的 `durationMs` **不是一个数**：库里那份是导入时读标签得来的，
    /// 这一份是解码器自己算的。两个都可能对、也可能差一点（坏标签、变长编码都会差）。
    /// 界面画进度用 `resolvedPlaybackDuration`：引擎优先，库兜底。**不在这儿合并。**
    /// `0` ＝ 还不知道（装载中就还没算出来）。
    var duration: TimeInterval

    /// 当前曲引擎还没装过。冷恢复后为 `true`：有歌、暂停，但不能 `resume()`。
    ///
    /// 迷你条进度认这一份：没装过不画；`start` / 切歌清掉之后才画。播过再暂停仍是 `false`。
    /// 不是第二套播放态，也不另造开关。
    var engineNeedsPrepare: Bool = false

    /// 当前播放模式（互斥四档）。
    ///
    /// 🔴 它是**队列的输入**：走到队尾时靠它决定回头还是停；是否洗牌也只看它是不是
    /// `.shuffle`。所以必须和队列待在同一份状态里。
    var playbackMode: PlaybackMode = .sequential

    /// 播放态。
    ///
    /// ⚠️ **用 enum、不用整数**：库那边是 `stopped(0) / paused(1) / playing(3)`
    /// （注意**没有 2**），早先那版照抄了这套数字、又自己往上加状态，最后判断散成一片位运算。
    /// 换成 enum 之后 `switch` 强制穷举，漏一个分支编译器就报错。
    enum Status: Equatable {
        /// 什么都没装。
        case idle

        /// 正在装载：开文件 / 建解码器。
        ///
        /// ⚠️ 这个态是**我们自己加的**（库不认识它），而它挡的不是"慢"，是**"引擎在撒谎"** ——
        /// 库在**引擎一启动就报「在播」**，那一刻文件还没打开、甚至可能打不开。
        /// ⇒ 「在播」这句要等解码器真的起来才认（见 `Decisions/PlaybackStatusPolicy.swift`）。
        case loading

        case playing
        case paused

        /// 播完了，但**还装着**这一首（下次点播放是从头还是从尾，等队列那一步再定）。
        case stopped

        /// 🔴 **这一首压根没放成**（文件没了 / 格式不支持 / 引擎坏了）。
        ///
        /// 和 `stopped` 是两件事：`stopped` ＝ "放完了"，这个是 ＝ "没放成"。
        /// 界面靠它把「听完了」和「听不了」分开说 —— 两者都停在原地，但意思完全不同。
        ///
        /// ⚠️ **"为什么没放成"不在这里** —— 它是一条**发一次就完的流**
        /// （`PlayManager.failureReason`），不是状态：界面弹一句就走，
        /// **没有一处需要"持久地看着原因"**（文案见 `PlaybackError+Display` ＋
        /// `播放错误提示设计.md`）。
        case failed
    }

    /// 打开 App 时的样子 —— 也是迷你条上「未在播放」那一屏。
    static let idle = PlayerState(track: nil, status: .idle, duration: 0)

    /// 播放会话是否活跃 —— 「在装」和「在播」都算。
    ///
    /// 🔴 **凡是要画「播放/暂停那个键」的地方都用它** —— App 内（迷你条 / 播放页 /
    /// 歌词条）、**锁屏 / 控制中心的按钮图态**、小组件按钮，一处不落。
    /// **"在装"也算在播**：用户刚点了这一首，那几百毫秒里他要看到的就是"在播"；
    /// 画成"没在播"的话，换歌时会先闪一下播放键、再跳回暂停键。
    ///
    /// ⚠️ 它**不是**"现在出没出声" —— `.loading` 时它是 `true`，但还没出声
    /// （那个态挡的是"引擎一启动就报在播"，见 `Status.loading`）。
    /// 要"真的在出声吗"（锁屏那条**进度速率**、列表竖条、队列声波），
    /// 用的是**下面那个** `isActuallyPlaying` —— 别拿这个去报进度。
    ///
    /// ⚠️ **写成 `switch` 是为了穷举**：`Status` 多一个态时这里会当场编译不过。
    /// 换成 `status == .playing || status == .loading` 就没这个保护了。
    var isPlaybackActive: Bool {
        switch status {
        case .playing, .loading:
            return true
        case .paused, .stopped, .failed, .idle:
            return false
        }
    }

    /// **现在真的在出声吗** —— 只有 `playing` 算，装载中不算。
    ///
    /// 🔴 它和上面那个 `isPlaybackActive` 答的是**两个问题**，别互相替代：
    /// - `isPlaybackActive`（在装 / 在播）—— 给**播放/暂停那个键**用：用户刚点了这一首，
    ///   那几百毫秒里他要看到"在播"；
    /// - 这一个 —— 给需要"真出声"的地方用：锁屏那条**进度速率**（装载中报 `0`，
    ///   否则进度条会从"文件还没打开"就开始走）、列表竖条、队列声波。
    ///
    /// ⚠️ 同样是 `switch` 穷举，理由同上。
    var isActuallyPlaying: Bool {
        switch status {
        case .playing:
            return true
        case .loading, .paused, .stopped, .failed, .idle:
            return false
        }
    }
}
