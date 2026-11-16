import UIKit

/// 均衡器的响应曲线。**只读**：不吃手势、不进无障碍树 —— 数值在十条滑条上。
///
/// 画四层：填充（曲线下方）· 0dB 基线 · 曲线 · 10 个频点圆点。
/// 横向**按下面那排滑条铺**（`EQResponsePolicy.horizontalFraction`）：
/// 第 k 个频点正对第 k 根滑条的中心，不是 20Hz–20kHz 的对数轴 —— 那个会让整排圆点偏右。
///
/// 🔴 **只主线程**（UIKit）。`show` 只存值，路径在 `layoutSubviews` 里重建；
/// 拖滑条时每帧 160 个点，够快，不要为它加节流或异步。
final class EQCurveView: UIView {

    private let fillLayer = CAShapeLayer()
    private let baselineLayer = CAShapeLayer()
    private let lineLayer = CAShapeLayer()
    private let dotLayer = CAShapeLayer()
    private var response: EQResponse?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        styleLayers()
        for sublayer in [fillLayer, baselineLayer, lineLayer, dotLayer] {
            layer.addSublayer(sublayer)
        }
    }

    required init?(coder: NSCoder) {
        // 本视图只由代码构造 —— 从 nib / storyboard 解档是写错了：调试期当场停下，正式版返回 nil。
        assertionFailure("EQCurveView 只由代码构造，不该走 init(coder:)")
        return nil
    }

    func show(_ response: EQResponse) {
        self.response = response
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        [fillLayer, baselineLayer, lineLayer, dotLayer].forEach { $0.frame = bounds }
        guard let response = response else {
            clearPaths()
            return
        }
        let plot = bounds.insetBy(dx: 0, dy: AppMetrics.equalizerCurveVerticalPadding)
        guard plot.width > 0, plot.height > 0, response.points.count > 1 else {
            clearPaths()
            return
        }
        rebuild(response, plot: plot)
    }

    // MARK: - 路径

    private func rebuild(_ response: EQResponse, plot: CGRect) {
        let curve = curvePath(response, plot: plot)
        lineLayer.path = curve.cgPath
        fillLayer.path = filledPath(curve, plot: plot).cgPath
        baselineLayer.path = baselinePath(plot: plot).cgPath
        dotLayer.path = dotPath(response, plot: plot).cgPath
    }

    private func curvePath(_ response: EQResponse, plot: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        for (index, point) in response.points.enumerated() {
            let location = CGPoint(
                x: x(point.frequency, plot: plot),
                y: y(point.decibels, scale: response.scaleDecibels, plot: plot)
            )
            if index == 0 {
                path.move(to: location)
            } else {
                path.addLine(to: location)
            }
        }
        return path
    }

    /// 曲线下方一直填到画布底：面积靠它把"抬/降"读出来。
    private func filledPath(_ curve: UIBezierPath, plot: CGRect) -> UIBezierPath {
        let path = UIBezierPath(cgPath: curve.cgPath)
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        path.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        path.close()
        return path
    }

    private func baselinePath(plot: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: plot.minX, y: plot.midY))
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        return path
    }

    /// 10 个圆点就画在 10 个频点上 —— x 跟曲线走**同一个** `horizontalFraction`。
    ///
    /// `31Hz` 进去正好是第 0 根滑条的中心 `0.05`，所以"圆点对齐滑条"是那条映射的推论，
    /// 不是另外凑出来的一行算式。
    private func dotPath(_ response: EQResponse, plot: CGRect) -> UIBezierPath {
        let side = AppMetrics.equalizerCurveDotSide
        let path = UIBezierPath()
        for point in response.bandPoints {
            let center = CGPoint(
                x: x(point.frequency, plot: plot),
                y: y(point.decibels, scale: response.scaleDecibels, plot: plot)
            )
            path.append(UIBezierPath(
                ovalIn: CGRect(
                    x: center.x - side / 2,
                    y: center.y - side / 2,
                    width: side,
                    height: side
                )
            ))
        }
        return path
    }

    private func x(_ frequency: Double, plot: CGRect) -> CGFloat {
        plot.minX + plot.width * EQResponsePolicy.horizontalFraction(for: frequency)
    }

    private func y(_ decibels: Float, scale: Float, plot: CGRect) -> CGFloat {
        let bound = max(scale, 1)
        let clamped = min(max(decibels, -bound), bound)
        return plot.midY - CGFloat(clamped / bound) * plot.height / 2
    }

    private func clearPaths() {
        fillLayer.path = nil
        baselineLayer.path = nil
        lineLayer.path = nil
        dotLayer.path = nil
    }

    // MARK: - 皮

    private func styleLayers() {
        fillLayer.fillColor = AppColor.accent
            .withAlphaComponent(AppMetrics.equalizerCurveFillOpacity)
            .cgColor
        fillLayer.strokeColor = nil

        baselineLayer.fillColor = nil
        baselineLayer.strokeColor = AppColor.overlayBorder.cgColor
        baselineLayer.lineWidth = AppMetrics.equalizerCurveBaselineWidth

        lineLayer.fillColor = nil
        lineLayer.strokeColor = AppColor.accent.cgColor
        lineLayer.lineWidth = AppMetrics.equalizerCurveLineWidth
        lineLayer.lineJoin = .round
        lineLayer.lineCap = .round

        dotLayer.fillColor = AppColor.nowPlayingSolid.cgColor
        dotLayer.strokeColor = nil
    }
}
