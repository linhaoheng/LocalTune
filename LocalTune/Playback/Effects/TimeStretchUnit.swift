import AVFAudio
import Foundation

/// 变速不变调。`overlap = 8`、`pitch = 0`；`1×` 旁路。
final class TimeStretchUnit {

    let node: AVAudioUnitTimePitch

    init() {
        let stretch = AVAudioUnitTimePitch()
        stretch.overlap = 8
        stretch.pitch = 0
        stretch.rate = 1
        stretch.bypass = true
        node = stretch
    }

    func apply(_ rate: PlaybackRate) {
        node.rate = float(for: rate)
        switch timeStretchBypass(for: rate) {
        case .bypass: node.bypass = true
        case .engage: node.bypass = false
        }
    }
}
