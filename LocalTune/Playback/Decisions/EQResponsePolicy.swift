import Foundation

/// `EQGains` → 一条响应曲线。纯函数、零 IO、不碰 `AVAudioEngine`。
///
/// 算的是**十段数字滤波器在给定采样率下**的响应：每段按 RBJ peaking 求幅度，
/// dB 相加，最后加前级。不是"把十根滑条连成一条折线"——相邻段会互相叠加。
///
/// ⚠️ **为什么带采样率**：曲线描述的是数字滤波器，系数按 fs 算。
/// 18kHz 以下不同采样率几乎重合，越靠近 Nyquist 差得越多
/// （44.1k 与 48k 在 20kHz 相差约 0.7dB、21kHz 约 1.2dB）。
/// 不读引擎的真实采样率，就只能拍一个数，越靠近高频越说不清。
enum EQResponsePolicy {

    /// 从左到右 160 个点：320pt 宽时约 2pt 一点，够平滑、算起来也不贵。
    static let pointCount = 160

    /// 画到 20Hz–20kHz：两端都比 31Hz / 16k 多留一点，圆点不会贴边。
    static let minimumFrequency: Double = 20
    static let maximumFrequency: Double = 20_000

    /// 纵轴只在这六档里选 —— 免得拖一下滑块整条曲线就改比例。
    static let scaleSteps: [Float] = [6, 12, 18, 24, 30, 36]

    static func response(for gains: EQGains, sampleRate: Double) -> EQResponse {
        let rate = usableSampleRate(sampleRate)
        let points = sampledFrequencies().map {
            EQResponsePoint(
                frequency: $0,
                decibels: decibels(at: $0, for: gains, sampleRate: rate)
            )
        }
        let bandPoints = EQSpec.frequencies.map {
            EQResponsePoint(
                frequency: Double($0),
                decibels: decibels(at: Double($0), for: gains, sampleRate: rate)
            )
        }
        // 纵轴按**全部**采样点 ＋ 10 个频点一起定 —— 频点不落在采样点上，
        // 只按 `points` 定刻度的话，圆点理论上能顶出画布。
        let all = points.map(\.decibels) + bandPoints.map(\.decibels)
        return EQResponse(
            points: points,
            bandPoints: bandPoints,
            scaleDecibels: scale(for: all)
        )
    }

    /// 任意频率处的响应（dB，含前级）。
    ///
    /// 曲线是它在 160 个采样点上的取值；校准测试拿它和节点实测对账。
    static func decibels(
        at frequency: Double,
        for gains: EQGains,
        sampleRate: Double
    ) -> Float {
        let rate = usableSampleRate(sampleRate)
        var total = Double(gains.preamp)
        for (band, center) in EQSpec.frequencies.enumerated() {
            let gain = gains.bands.indices.contains(band) ? gains.bands[band] : 0
            guard gain != 0 else { continue }
            total += decibels(
                gain: Double(gain),
                center: Double(center),
                frequency: frequency,
                sampleRate: rate
            )
        }
        return Float(total)
    }

    // MARK: - 采样

    /// 采样率异常（还没连引擎时给 0）时留一个可算的下限；真实值由引擎回填。
    private static func usableSampleRate(_ sampleRate: Double) -> Double {
        max(sampleRate, 8_000)
    }

    private static func sampledFrequencies() -> [Double] {
        let step = log(maximumFrequency / minimumFrequency) / Double(pointCount - 1)
        return (0..<pointCount).map { index in
            minimumFrequency * exp(step * Double(index))
        }
    }

    // MARK: - 横轴

    /// 频率 → 相对横坐标（`0…1`），**按下面那排滑条铺**，不是按 20Hz–20kHz 的对数轴。
    ///
    /// ## 为什么不能直接用对数轴
    ///
    /// 滑条排是 10 等分，第 k 根的中心在 `(k + 0.5) / 10`（`0.05, 0.15 … 0.95`）。
    /// 而 10 个频点（31Hz–16kHz）在 20Hz–20kHz 的对数轴上落在 `6.3%…96.8%` ——
    /// 每个圆点都比滑条中心偏右，而且**越往右偏得越多**（间距 10.03% 对 10%）。
    /// 390pt 宽的手机上从 4.8pt 一路偏到 6.9pt，就是肉眼看得见的那"一点点"。
    ///
    /// ## 怎么铺
    ///
    /// 第 k 个频点钉死在 `(k + 0.5) / 10`，**段内仍按对数插值**（曲线形状不变），
    /// 两端（20→31Hz、16k→20kHz）各占半格。
    static func horizontalFraction(for frequency: Double) -> Double {
        let centers = EQSpec.frequencies.map { Double($0) }
        guard let first = centers.first, let last = centers.last, centers.count > 1 else {
            return 0.5
        }
        let slot = 1 / Double(centers.count)

        // 只在**越出两端**时走这两个分支；正好等于第一个 / 最后一个频点的，
        // 交给下面那个循环（`ratio == 0`），边界不必两处各判一次。
        if frequency < first {
            return slot / 2 * logRatio(from: minimumFrequency, to: first, value: frequency)
        }
        if frequency > last {
            let tail = logRatio(from: last, to: maximumFrequency, value: frequency)
            return 1 - slot / 2 * (1 - tail)
        }
        for band in 0..<(centers.count - 1) where frequency < centers[band + 1] {
            let ratio = logRatio(from: centers[band], to: centers[band + 1], value: frequency)
            return (Double(band) + 0.5 + ratio) * slot
        }
        // 正好等于最后一个频点。
        return 1 - slot / 2
    }

    private static func logRatio(from low: Double, to high: Double, value: Double) -> Double {
        guard high > low, value > 0 else { return 0 }
        return log(value / low) / log(high / low)
    }

    // MARK: - 单段

    /// 单段 RBJ peaking 在 `frequency` 处的幅度（dB）。
    ///
    /// 带宽按 AudioUnit 文档的定义：上下边频（增益为峰值一半）之间的**倍频程数**。
    /// `alpha` 用 RBJ 的带宽版（含双线性变换的预畸变），不是"Q = 常数"那种近似。
    /// 公式与节点是否一致，由校准测试对账 —— 不许靠注释自证。
    private static func decibels(
        gain: Double,
        center: Double,
        frequency: Double,
        sampleRate: Double
    ) -> Double {
        let amplitude = pow(10, gain / 40)
        let w0 = 2 * Double.pi * center / sampleRate
        let bandwidth = Double(EQSpec.bandwidth)
        let alpha = sin(w0) * sinh(log(2) / 2 * bandwidth * w0 / sin(w0))
        let b0 = 1 + alpha * amplitude
        let b1 = -2 * cos(w0)
        let b2 = 1 - alpha * amplitude
        let a0 = 1 + alpha / amplitude
        let a1 = -2 * cos(w0)
        let a2 = 1 - alpha / amplitude

        let w = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w)
        let sinW = sin(w)
        let cosW2 = cos(2 * w)
        let sinW2 = sin(2 * w)

        let numeratorReal = b0 + b1 * cosW + b2 * cosW2
        let numeratorImaginary = -(b1 * sinW + b2 * sinW2)
        let denominatorReal = a0 + a1 * cosW + a2 * cosW2
        let denominatorImaginary = -(a1 * sinW + a2 * sinW2)

        let numerator = numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary
        let denominator = denominatorReal * denominatorReal
            + denominatorImaginary * denominatorImaginary
        guard denominator > 0, numerator > 0 else { return 0 }

        return 10 * log10(numerator / denominator)
    }

    // MARK: - 纵轴

    private static func scale(for decibels: [Float]) -> Float {
        let peak = decibels.reduce(Float(0)) { max($0, abs($1)) }
        return scaleSteps.first { $0 >= peak } ?? scaleSteps[scaleSteps.count - 1]
    }
}
