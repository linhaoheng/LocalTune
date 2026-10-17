import Foundation

/// 9 条内置曲线。
///
/// 前级一律 0：没有前级就不发明补偿。纯数据、零 IO，判断和执行都要用 ⇒ 在 `Model/`。
enum EQBuiltInGains {

    static func gains(for preset: EQBuiltInPreset) -> EQGains {
        EQGains(bands: bands(for: preset), preamp: 0)
    }

    static func bands(for preset: EQBuiltInPreset) -> [Float] {
        switch preset {
        case .plusEqual: [5, -6, -5, 5, 4, 5, 6, 6, 5, -7]
        case .harman: [1, 2, 2, 0, 0, 2, 3, 3, 2, 1]
        case .pop: [3, 2, 0, 0, 1, 2, 3, 2, 1, 0]
        case .rock: [4, 3, 1, 0, -1, 0, 2, 3, 3, 2]
        case .jazz: [2, 1, 0, 1, 2, 2, 1, 0, 1, 2]
        case .classical: [3, 2, 0, 0, 0, 0, 1, 2, 3, 4]
        case .vocal: [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]
        case .bass: [6, 5, 3, 1, 0, 0, 0, 0, 0, 0]
        case .electronic: [5, 4, 1, 0, -1, 1, 0, 2, 3, 4]
        }
    }
}
