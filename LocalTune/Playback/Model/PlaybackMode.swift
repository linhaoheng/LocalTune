import Foundation

/// 全场唯一的播放走法 —— **四档互斥**，同时只能有一种。
///
/// 存在 `PlayerState.playbackMode`。随机是独立一档，**不是**「循环 × 洗牌」的组合。
enum PlaybackMode: String, CaseIterable, Codable {
    /// 顺序播放 —— 自动播完到头停。
    case sequential

    /// 列表循环。
    case all

    /// 单曲循环。
    case one

    /// 随机播放 —— 队列打乱；自动播完到头停（走法同顺序）。
    case shuffle
}
