import Foundation

/// 磁盘上那份播放会话 —— 冷数据，不是活状态。
///
/// 出处：`播放存档设计.md` §4.1。活状态只在 `PlayManager`。
struct PlaybackSessionSnapshot: Equatable, Codable {
    static let currentVersion = 1

    var version: Int
    /// 当时的播放顺序（`PlayQueue.trackIDs`）。
    var trackIDs: [String]
    /// 关洗牌时要回到的顺序（`original` 的 id）。
    var originalIDs: [String]
    /// 还没轮到的「下一首播放」（`upNext` 的 id）。
    var upNextIDs: [String]
    var currentIndex: Int
    var position: TimeInterval
    var playbackMode: PlaybackMode
    /// 杀掉前是不是在播 —— 只记；恢复不自动播。
    var wasPlaying: Bool
    var updatedAt: Date
}

/// 存档要的那个「队列此刻的样子」—— 三份顺序 ＋ 游标。**纯值，没有行为**。
///
/// ⚠️ 为什么是个**具名类型**而不是 `PlayQueue` 里那个元组：它是纯函数
/// `playbackSessionSnapshot(…)` 的入参，元组当不了类型名，签名会变成一坨；
/// 而且元组没法标 `Equatable`，测试里比对不了。
///
/// ⚠️ **没有 `isShuffled`**：快照里存的是**用户的播放模式**（`PlaybackMode`，从 `PlayerState` 取），
/// 洗牌开关是队列自己的实现细节 —— 存进去也没人读。
struct PlaybackQueueCapture: Equatable {
    var trackIDs: [Track.ID]
    var originalIDs: [Track.ID]
    var upNextIDs: [Track.ID]
    var currentIndex: Int
}

/// 校验 + 修剪之后的恢复计划（只含 id）。`Track` 由装配按 id 查库填。
struct PlaybackSessionRestorationPlan: Equatable {
    var trackIDs: [String]
    var originalIDs: [String]
    var upNextIDs: [String]
    var currentIndex: Int
    /// 已过 3s 门槛与夹取。
    var position: TimeInterval
    var playbackMode: PlaybackMode
    /// 恒 `false`（产品：记得但不自动播）。
    var shouldStartPlayback: Bool
}

/// 启动恢复生命周期 —— 对齐 primuse `PlaybackSessionRestoreLifecycle`，纯值、无 IO。
struct PlaybackSessionRestoreLifecycle: Equatable {
    enum Phase: Equatable {
        case pending
        case restoring
        case superseded
        case completed
    }

    private(set) var phase: Phase = .pending
    private var generation: UInt64 = 0

    /// 恢复没结束前，空态不许清档。
    var permitsEmptySessionClear: Bool { phase == .completed }

    /// 开始唯一一次启动恢复；已开始过 ⇒ `nil`。
    mutating func begin() -> UInt64? {
        guard phase == .pending else { return nil }
        generation &+= 1
        phase = .restoring
        return generation
    }

    func permitsApply(token: UInt64) -> Bool {
        phase == .restoring && generation == token
    }

    mutating func complete(token: UInt64) {
        guard permitsApply(token: token) else { return }
        phase = .completed
    }

    /// 用户点播 ⇒ 作废在飞的恢复。
    mutating func supersedeForPlaybackIntent() {
        guard phase == .pending || phase == .restoring else { return }
        generation &+= 1
        phase = .superseded
    }

    mutating func didPersistCurrentSession() {
        phase = .completed
    }

    mutating func completeForPauseOrStopIntent() {
        generation &+= 1
        phase = .completed
    }
}

/// 磁盘要落到的状态。
enum PlaybackSessionPersistenceRequest: Equatable {
    case save(PlaybackSessionSnapshot)
    case clear
}
