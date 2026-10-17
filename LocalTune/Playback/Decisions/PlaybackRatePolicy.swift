import Foundation

/// 档 → 节点 / 锁屏要的 `Float`。
func float(for rate: PlaybackRate) -> Float {
    switch rate {
    case .x075: 0.75
    case .x1: 1
    case .x125: 1.25
    case .x15: 1.5
    case .x2: 2
    }
}

/// `1×` 旁路。枚举穷举，不再拿浮点去比。
func timeStretchBypass(for rate: PlaybackRate) -> EffectsNodeBypass {
    rate == .x1 ? .bypass : .engage
}
