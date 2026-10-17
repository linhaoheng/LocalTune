import Foundation

/// 队列某一侧「有没有可切的邻居」—— 迷你条滑动预览 / 播放页封面拖切 / 能不能提交，同一条口令。
///
/// 🔴 **判断归位**：返回 enum，不返回 `Bool`。
/// 预览和 `playPrevious` / `playNext` 必须认**同一份 peek**；另写一份 `adjacentTrack`
/// 看不到插队，才会「滑过去封面是 A、耳朵是 B」—— 不许再抄。
enum QueueNeighbor {

    /// 这一侧有歌可切。
    case available(Track)

    /// 这一侧没有（顺序播放停在队首 / 队尾、或队列空）。
    case unavailable
}

/// 把 `PlayQueue.peek*` 的结果翻成「能不能往这边切」。
func queueNeighbor(peeked: Track?) -> QueueNeighbor {
    if let track = peeked { return .available(track) }
    return .unavailable
}
