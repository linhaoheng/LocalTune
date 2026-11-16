import Foundation

/// 控制中心是循环、随机两条轴；内部只有 `PlaybackMode` 四档。
/// 投影出去给人看，收进来落回四档之一。开随机就离开循环，开循环就离开随机。
func remotePlaybackFaces(for mode: PlaybackMode) -> (repeat: RemoteRepeatFace, shuffle: RemoteShuffleFace) {
    switch mode {
    case .sequential:
        return (.off, .off)
    case .all:
        return (.all, .off)
    case .one:
        return (.one, .off)
    case .shuffle:
        return (.off, .items)
    }
}

func playbackMode(afterRemoteRepeat face: RemoteRepeatFace, current: PlaybackMode) -> PlaybackMode {
    switch face {
    case .off:
        switch current {
        case .all, .one: return .sequential
        case .sequential, .shuffle: return current
        }
    case .all:
        return .all
    case .one:
        return .one
    }
}

func playbackMode(afterRemoteShuffle face: RemoteShuffleFace, current: PlaybackMode) -> PlaybackMode {
    switch face {
    case .items:
        return .shuffle
    case .off:
        return current == .shuffle ? .sequential : current
    }
}
