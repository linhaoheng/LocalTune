import Foundation

/// 宽限到期后，引擎态还算活着吗。
///
/// 出处：Cosmos `SFBAudioEngineManager.audioPlayer(_:encounteredError:)` ——
/// `isPlaying || isPaused` 任一为真就放过。
func engineErrorAfterGrace(isPlaying: Bool, isPaused: Bool) -> EngineErrorAfterGrace {
    (isPlaying || isPaused) ? .recovered : .fatal
}
