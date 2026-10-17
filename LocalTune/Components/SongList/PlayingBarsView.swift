import UIKit

/// 列表行「正在播放」的四根竖条 —— **装饰指示**，不是频谱。
///
/// 几何：条宽 1.6、间距 1.8、固有尺寸 12×16。
/// 🔴 **条的底线不贴视图下沿，而是让整组的外接盒在视图里居中**（见 `baselineY`）——
/// 这一条管着"跟同一行的文字对不对得齐"。
/// 动效借 **NAK**（CA `bounds` 高度 + `autoreverses` + 暂停衰减）和 **Cosmos**
/// （四杠固定错落时长 + 回前台重开）。
final class PlayingBarsView: UIView {

    private let bars = (0..<4).map { _ in UIView() }

    /// 用户要不要跳（跟「动画层上此刻有没有在跳」分开 —— 回前台要靠它重开）。
    private var shouldPlay = false
    /// 循环动画是不是已经挂上了。
    private var isOscillating = false
    /// 暂停衰减是不是正在跑 —— layout 期间不能 resetHeights，否则衰减会被立刻掐掉。
    private var isDecaying = false

    private let barWidth: CGFloat = 1.6
    private let spacing: CGFloat = 1.8
    /// 静帧 / 暂停落点：短、长、更短、中。
    private let startHeights: [CGFloat] = [5, 11, 3, 8]
    /// 跳动峰值（错落）。
    private let endHeights: [CGFloat] = [8, 5, 11, 3]

    /// 条组的**外接盒**高度 —— 静帧与峰值里最高的那根。
    ///
    /// 🔴 它是"对齐"的落脚点：四根条在盒里是**贴底**长的，所以**盒子居中 ⇒ 条的轮廓居中**。
    private var envelopeHeight: CGFloat {
        max(startHeights.max() ?? 0, endHeights.max() ?? 0)
    }

    /// 四根条共用的**底线**。
    ///
    /// 🔴 是"外接盒在视图里居中"（`midY + 盒高/2`），**不是**贴视图下沿。
    /// 拿视图下沿当底线 ⇒ 整组沉到容器下半部、比同一行的歌名低一截（20×20 的容器
    /// 配 11pt 的盒，重心低 4.5pt）。那组动画其实是一张 **14×14 的图居中**在
    /// 20×20 的容器里（上下各留 1pt）—— 等价于"外接盒居中"。
    /// 盒高是常量 ⇒ 底线不随动画抖。
    private var baselineY: CGFloat { bounds.midY + envelopeHeight / 2 }
    /// 错落时长 —— 比 Cosmos 原档 `[0.6, 0.8, 0.4, 0.7]` 整体放慢一截：
    /// 那根 `0.4` 太赶；落在 NAK / EqualizerIndicatorView 常用的 ~0.75–1.2 一带。
    /// （`autoreverses` 下这是**单程**秒数，来回一圈 ≈ 两倍。）
    private let durations: [CFTimeInterval] = [0.9, 1.15, 0.75, 1.05]
    /// NAK 暂停衰减时长。
    private let decayDuration: CFTimeInterval = 0.3

    private let oscillationKey = "eq-height"
    private let decayKey = "eq-decay"

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        clipsToBounds = true
        bars.forEach { bar in
            bar.backgroundColor = AppColor.accent
            bar.layer.cornerRadius = 0.5
            bar.layer.masksToBounds = true
            // 关掉边沿再抗锯齿 —— 半像素上会把某一根「吃」得更细。
            bar.layer.allowsEdgeAntialiasing = false
            addSubview(bar)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var intrinsicContentSize: CGSize { CGSize(width: 12, height: 16) }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 跳动 / 衰减中只重排水平位置，别把高度刷回静帧（否则动画当场被掐）。
        layoutBars(resetHeights: !isOscillating && !isDecaying)
        CATransaction.commit()
    }

    /// 开 / 关跳动。正在播就跳；暂停或不是当前行 → 衰减回静帧。
    func setPlaying(_ playing: Bool) {
        shouldPlay = playing
        if playing {
            startOscillation()
        } else {
            stopOscillation(decay: true)
        }
    }

    // MARK: - 私有

    /// 点 → 像素对齐。1.6pt 在 @3x 上是 4.8px，不齐的话某一根会糊边、看起来更细。
    private func pixelAlign(_ value: CGFloat) -> CGFloat {
        let scale = traitCollection.displayScale
        guard scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }

    /// 四根条水平居中、贴底。宽 / 起点都钉在像素上，粗细一致。
    private func layoutBars(resetHeights: Bool) {
        let width = pixelAlign(barWidth)
        let gap = pixelAlign(spacing)
        let total = CGFloat(bars.count) * width + CGFloat(bars.count - 1) * gap
        var x = pixelAlign((bounds.width - total) / 2)
        for (index, bar) in bars.enumerated() {
            bar.layer.anchorPoint = CGPoint(x: 0.5, y: 1)
            bar.layer.contentsScale = traitCollection.displayScale
            if resetHeights {
                let height = min(startHeights[index], bounds.height)
                bar.layer.removeAnimation(forKey: oscillationKey)
                bar.layer.removeAnimation(forKey: decayKey)
                bar.frame = CGRect(x: x, y: baselineY - height, width: width, height: height)
            } else {
                // 跳动中只钉底边水平位置，**不动高度** —— 高度交给 CA 插值。
                bar.layer.position = CGPoint(x: pixelAlign(x + width / 2), y: baselineY)
                // 宽也钉死，避免动画过程中模型宽漂成非像素值。
                var bounds = bar.layer.bounds
                bounds.size.width = width
                bar.layer.bounds = bounds
            }
            x = pixelAlign(x + width + gap)
        }
    }

    private func startOscillation() {
        guard !isOscillating else { return }
        isDecaying = false
        // 先按静帧排好，再挂循环。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutBars(resetHeights: true)
        CATransaction.commit()
        isOscillating = true
        let width = pixelAlign(barWidth)
        for (index, bar) in bars.enumerated() {
            bar.layer.removeAnimation(forKey: decayKey)
            bar.layer.removeAnimation(forKey: oscillationKey)
            let from = startHeights[index]
            let to = endHeights[index]
            bar.layer.position = CGPoint(x: pixelAlign(bar.frame.midX), y: baselineY)
            bar.layer.bounds = CGRect(x: 0, y: 0, width: width, height: from)

            let heightAnim = CABasicAnimation(keyPath: "bounds.size.height")
            heightAnim.fromValue = from
            heightAnim.toValue = to
            heightAnim.duration = durations[index]
            heightAnim.repeatCount = .infinity
            heightAnim.autoreverses = true
            heightAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.layer.add(heightAnim, forKey: oscillationKey)
        }
    }

    /// - Parameter decay: `true` = NAK 式收到静帧；`false` = 立刻落静帧。
    private func stopOscillation(decay: Bool) {
        // 已经在衰减：列表会反复 `setPlaying(false)`，别再 settle 把衰减掐掉。
        if isDecaying { return }

        let hadOscillation = isOscillating
            || bars.contains { $0.layer.animation(forKey: oscillationKey) != nil }
        isOscillating = false
        guard hadOscillation else {
            settleIdle(animated: false)
            return
        }
        if decay {
            isDecaying = true
            let width = pixelAlign(barWidth)
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, !self.shouldPlay else { return }
                self.isDecaying = false
            }
            for (index, bar) in bars.enumerated() {
                let presented = bar.layer.presentation()?.bounds.height ?? bar.layer.bounds.height
                bar.layer.removeAnimation(forKey: oscillationKey)
                bar.layer.removeAnimation(forKey: decayKey)
                let target = startHeights[index]
                bar.layer.position = CGPoint(x: pixelAlign(bar.frame.midX), y: baselineY)
                bar.layer.bounds = CGRect(x: 0, y: 0, width: width, height: presented)

                let decayAnim = CABasicAnimation(keyPath: "bounds.size.height")
                decayAnim.fromValue = presented
                decayAnim.toValue = target
                decayAnim.duration = decayDuration
                decayAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.layer.bounds = CGRect(x: 0, y: 0, width: width, height: target)
                bar.layer.add(decayAnim, forKey: decayKey)
            }
            CATransaction.commit()
        } else {
            isDecaying = false
            settleIdle(animated: false)
        }
    }

    private func settleIdle(animated: Bool) {
        let width = pixelAlign(barWidth)
        for (index, bar) in bars.enumerated() {
            bar.layer.removeAnimation(forKey: oscillationKey)
            bar.layer.removeAnimation(forKey: decayKey)
            let target = startHeights[index]
            bar.layer.position = CGPoint(x: pixelAlign(bar.frame.midX), y: baselineY)
            if animated {
                let from = bar.layer.presentation()?.bounds.height ?? bar.layer.bounds.height
                let decayAnim = CABasicAnimation(keyPath: "bounds.size.height")
                decayAnim.fromValue = from
                decayAnim.toValue = target
                decayAnim.duration = decayDuration
                decayAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.layer.bounds = CGRect(x: 0, y: 0, width: width, height: target)
                bar.layer.add(decayAnim, forKey: decayKey)
            } else {
                bar.layer.bounds = CGRect(x: 0, y: 0, width: width, height: target)
            }
        }
        setNeedsLayout()
    }

    /// CA 无限动画进后台常会停死 —— 回前台若仍该跳，整组重挂（NAK / Cosmos 同款）。
    @objc private func applicationWillEnterForeground() {
        guard shouldPlay else { return }
        isOscillating = false
        isDecaying = false
        startOscillation()
    }
}
