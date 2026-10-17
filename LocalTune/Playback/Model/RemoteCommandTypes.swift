import Foundation

/// 远程命令这件事的**词汇表** —— 系统发来的一条命令，和我们对它的答复。
///
/// 🔴 **为什么在 `Model/` 而不是 `Decisions/`**：这两个类型**判断和执行都要用** ——
/// 判断（`Decisions/RemoteCommandPolicy.swift`）收 `RemoteCommand`、吐 `RemoteCommandAction`；
/// 执行也都要（`NowPlayingCenter` 产命令、拿答复去 `switch`）。
/// 宪法第一节：「同一个类型被『判断』和『执行』两边都用，却没在 `Model/`，就是环的雏形」
/// ⇒ 两边共用的类型**抽到最底 `Model/`**（同 `PlayerState` · `AudioSessionReason`）。
///
/// 系统循环 / 随机是两条轴，这里先收成我们的「脸」，再由政策落回 `PlaybackMode`。
/// 不在这儿出现 `MediaPlayer` 类型。
enum RemoteRepeatFace: Equatable {
    case off
    case one
    case all
}

enum RemoteShuffleFace: Equatable {
    case off
    case items
}

enum RemoteCommand: Equatable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
    case changePlaybackPosition(TimeInterval)
    case like(wantsFavorite: Bool)
    case changeRepeatMode(RemoteRepeatFace)
    case changeShuffleMode(RemoteShuffleFace)
}

/// 收到一条远程命令，**我们要做什么**。
///
/// 它是 enum 而不是 `Bool`：出问题时能一眼看出是「没东西可操作」还是「这条命令没必要做」，
/// 而不是一个 `false` —— 位运算那套正是它的反面。
enum RemoteCommandAction: Equatable {

    /// 没有可操作的东西（什么都没装）—— 回给系统「这儿没有在播的」。
    case noActionableItem

    /// 这条命令在当前状态下**没有意义**（已经在播还让它播）——
    /// 当作成功、什么都不做，**不许翻成相反的动作**。
    case ignore

    /// 把播放 / 暂停切一下。`play` / `pause` / `togglePlayPause` 三条都会落到这儿。
    case togglePlayPause

    case next
    case previous
    case seek(TimeInterval)
    case setFavorite(Bool)
    case setPlaybackMode(PlaybackMode)
}
