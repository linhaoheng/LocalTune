import Foundation

/// 队列此刻的样子 —— **播放顺序 + 现在第几格**，推给队列页画。
///
/// 🔴 **单独一份、不塞进 `PlayerState`**：迷你条、锁屏、播放页都订 `PlayerState`，
/// 队列混进去的话，它们每次播停都要把整条队列比一遍；只有队列页关心这一份。
///
/// ⚠️ 「当前」用**位置**说、不用歌曲 id：正在播的那首点过「下一首播放」时，
/// 队列里有它的两份（见 `PlayQueue.insertNext`），按 id 认会亮两行。
struct QueueSnapshot: Equatable {

    /// 现在的播放顺序（开着随机播放就是打乱后的那份）。
    let tracks: [Track]

    /// 现在播的是第几格；`nil` ＝ 当前那首已经不在队列里（或队列是空的）。
    let currentIndex: Int?

    static let empty = QueueSnapshot(tracks: [], currentIndex: nil)
}
