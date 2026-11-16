import Foundation

/// 档 → 节点 / 锁屏要的 `Float`。
///
/// ⚠️ 换算只有这一处：`PlaybackRate` 内部是整数百分数（比对要精确），
/// 出了这道门才变成引擎认的浮点。
func float(for rate: PlaybackRate) -> Float {
    Float(rate.hundredths) / 100
}

/// `1×` 旁路。
func timeStretchBypass(for rate: PlaybackRate) -> EffectsNodeBypass {
    rate == .x1 ? .bypass : .engage
}
