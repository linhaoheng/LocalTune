import Foundation

/// 播放模式键点一下：下一档。
func nextPlaybackMode(_ current: PlaybackMode) -> PlaybackMode {
    switch current {
    case .sequential: return .all
    case .all: return .one
    case .one: return .shuffle
    case .shuffle: return .sequential
    }
}
