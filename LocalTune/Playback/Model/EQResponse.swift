import Foundation

/// 曲线上的一个采样点：频率 + 该频率处的增益（已含前级）。
struct EQResponsePoint: Equatable {
    var frequency: Double
    var decibels: Float
}

/// 一条算好的 EQ 响应曲线，给界面照着画。
///
/// **不是**播放状态，也不是用户设置：它由 `EQGains` + 采样率现算，
/// 谁都不缓存（唯一真相仍是 `EffectsSession.gains`）。
struct EQResponse: Equatable {

    /// 从左到右、对数均分。界面拿每点的 `frequency` 换算横坐标
    /// （`EQResponsePolicy.horizontalFraction`），不按下标铺。
    var points: [EQResponsePoint]

    /// 10 个频点**本身**（31Hz、62Hz…16kHz）的响应，顺序跟 `EQSpec.frequencies` 一致 —— 画圆点用。
    ///
    /// ⚠️ 不是从 `points` 里挑最近的那个采样点：31Hz 的频点最近落在 30.87Hz 上，
    /// 挑出来的 dB 就不是 31Hz 的 dB。这里按频点**现算**，圆点画在哪儿、值就是哪儿的。
    var bandPoints: [EQResponsePoint]

    /// 纵轴对称刻度（±dB）。界面拿它定上下边界，曲线不会越出画布。
    var scaleDecibels: Float
}
