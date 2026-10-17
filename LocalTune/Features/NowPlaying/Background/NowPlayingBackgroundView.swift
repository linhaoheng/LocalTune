import UIKit

/// 播放页的背景 —— **一条斜向渐变 ＋ 一层黑压层**，颜色跟着封面走。
///
/// ```
/// scrim      黑压层：上 10% · 中 20% · 下 15%（白字压得住）
/// gradient   右上 → 左下；铺满
/// ```
///
/// ⚠️ **别做三层**：还有一种写法是加一条左上 → 右下的，
/// 但它和这一条都铺满、颜色都不透明，被后加的这一条整块盖死、从没上过屏。
/// 屏幕上的样子就是上面这两层 —— 我们只写看得见的（真机对过）。
///
/// 🔴 **它只画、不取色**：颜色是 `NowPlayingViewModel.background` 算好推来的（取色在后台、过期的丢掉）。
/// 刚建出来、还没收到第一份时画的是 `BackdropGradient.fallback` —— 跟"没封面"是**同一份**。
final class NowPlayingBackgroundView: UIView {

    private let gradient = CAGradientLayer()
    private let scrim = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        buildLayers()
        paint(.fallback)
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 对外

    /// 换一份颜色 —— 从**屏幕上此刻的颜色**渐变过去（0.8 秒）。
    ///
    /// ⚠️ 起点取 `presentation()`：上一次渐变还没走完时，屏幕上是半路的颜色；
    /// 取 `layer.colors`（上一次的**终点**）的话，半路切歌会先跳到上一首的终点色再开始渐变。
    func show(_ backdrop: BackdropGradient) {
        let colors = Self.cgColors(backdrop)
        let animation = CABasicAnimation(keyPath: "colors")
        animation.fromValue = gradient.presentation()?.colors ?? gradient.colors
        animation.toValue = colors
        animation.duration = AppMetrics.nowPlayingBackdropCrossfadeDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // 先改模型值、再挂动画：动画走完自动摘掉，留下的就是模型值 ——
        // 不需要那对 `fillMode = .forwards` + `isRemovedOnCompletion = false`（那会让动画一直挂着）。
        gradient.colors = colors
        gradient.add(animation, forKey: "colors")
    }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        // 跟着视图改尺寸是瞬时的事 —— 不关隐式动画的话，转屏时两层会各自慢慢"长"过去。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        scrim.frame = bounds
        CATransaction.commit()
    }

    // MARK: - 建立

    private func buildLayers() {
        gradient.startPoint = CGPoint(x: 1, y: 0)
        gradient.endPoint = CGPoint(x: 0, y: 1)

        scrim.startPoint = CGPoint(x: 0.5, y: 0)
        scrim.endPoint = CGPoint(x: 0.5, y: 1)
        scrim.locations = [0, 0.5, 1]
        scrim.colors = [
            AppColor.NowPlayingBackdrop.scrimTop.cgColor,
            AppColor.NowPlayingBackdrop.scrimMiddle.cgColor,
            AppColor.NowPlayingBackdrop.scrimBottom.cgColor,
        ]

        layer.addSublayer(gradient)
        layer.addSublayer(scrim)
    }

    /// 不带动画地铺上一份 —— 只在建出来那一刻用。
    private func paint(_ backdrop: BackdropGradient) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = Self.cgColors(backdrop)
        CATransaction.commit()
    }

    /// 算出来的颜色上屏 —— 这条链上**唯一**把 `PaletteColor` 换成系统颜色的地方。
    private static func cgColors(_ backdrop: BackdropGradient) -> [CGColor] {
        [backdrop.start, backdrop.end].map { color in
            CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        }
    }
}
