import AVFAudio
import Foundation

/// 10 段参量 EQ。只管节点上的数字和旁路，不存档、不认识预设名。
final class EQUnit {

    let node: AVAudioUnitEQ

    init() {
        let eq = AVAudioUnitEQ(numberOfBands: EQSpec.bandCount)
        eq.globalGain = 0
        for (index, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = EQSpec.frequencies[index]
            band.bandwidth = EQSpec.bandwidth
            band.gain = 0
            band.bypass = false
        }
        eq.bypass = true
        node = eq
    }

    func apply(_ gains: EQGains) {
        let clamped = clampedEQGains(bands: gains.bands, preamp: gains.preamp)
        node.globalGain = clamped.preamp
        for (index, band) in node.bands.enumerated() {
            band.gain = clamped.bands[index]
        }
        switch eqNodeBypass(for: clamped) {
        case .bypass: node.bypass = true
        case .engage: node.bypass = false
        }
    }
}
