import UIKit

/// 按下会缩放的按钮 —— 播放控件、工具栏按钮的手感统一走它。
///
/// 手感：**按下快、抬起慢**（时长在 `AppMetrics.pressDownDuration` / `pressUpDuration`），
/// 缓入缓出，缩到 **`0.8`**。跟手和弹回是两件事，所以那两个时长分开调。
///
/// ⚠️ Apple 那边按下时底下还有一圈高亮跟着收拢 —— **我们有意不做**。
///
/// 图标和颜色交给 `UIButton.Configuration`；**按下不叠变暗**走
/// `imageColorTransformer`（见 `init`）—— 不碰那个废弃的老开关。
///
/// 🔴 **缩的是图标（`imageView`），不是整个按钮** —— 照 Apple Music 的做法
/// （`sub_218160` 里动的是 `objc_msgSend(self, "imageView")` 的 transform）。
/// ⇒ 按钮有底圈时，**底圈不动、只有图标缩进去**。
///
/// ⚠️ 这个类**独占 `imageView` 的缩放动画** —— 外面别再给它的 `imageView` 加动画、也别设 `transform`。
final class PressScaleButton: PressableButton {

    // MARK: - 常量

    /// 缩放动画挂在 layer 上的 key。按下和抬起**共用**一个 —— 新的替换旧的，不会层层叠加。
    private static let scaleAnimationKey = "pressScale"

    // MARK: - 状态

    /// 图标现在停在哪个倍数上 —— 下一次**从这儿**接着动。
    ///
    /// ⚠️ 必须是「上一次的目标值」，**不能改成去问"此刻真实的大小"**：按下的动画有 `0.2` 秒，
    /// 而点一下只有约 `0.1` 秒 —— 抬手时图标才缩到一半，从真实值接着弹回只差一点点，
    /// 屏幕上几乎不动（实测：这么改之后「点按没动画」）。用目标值接，快按才有按下感。
    private var currentScale: CGFloat = 1

    /// 图标（SF Symbol 之类的模板图）。
    ///
    /// 图标多大由图标自己带 —— 要多大就在建 `UIImage` 时
    /// `applyingSymbolConfiguration` 定好，这里不再多一个尺寸参数。
    var icon: UIImage? {
        didSet { setNeedsUpdateConfiguration() }
    }

    /// 图标颜色。只从 `AppColor` 取。
    var iconColor: UIColor = AppColor.title {
        didSet { setNeedsUpdateConfiguration() }
    }

    init(icon: UIImage?, iconColor: UIColor = AppColor.title) {
        self.icon = icon
        self.iconColor = iconColor
        super.init(frame: .zero)

        // 图标按钮缩得比实心按钮多（0.8 vs 0.9），建的时候定下来。
        pressScale = 0.8

        var configuration = UIButton.Configuration.plain()
        // 不留内边距 —— 按钮就贴着图标，多大由图标说了算。
        configuration.contentInsets = .zero
        self.configuration = configuration

        configurationUpdateHandler = { [weak self] button in
            guard let self else { return }
            var updated = button.configuration ?? .plain()

            updated.image = self.icon
            // 把图自己带的那份尺寸配置转交给按钮 —— 少这一句，按钮会按**自己那套度量**
            // （`buttonSize` → 默认字体 → 图标尺寸）算大小，图上定的字号就白设了。
            updated.preferredSymbolConfigurationForImage = self.icon?.symbolConfiguration
            updated.baseForegroundColor = self.iconColor

            // 🔴 「按下只缩、不叠变暗」靠这里，**不能**靠 `baseForegroundColor`：
            // 它只是"基础色"，UIKit 会先按状态把颜色改掉、再交给 transformer
            // （SDK 原话："This color may be modified before being passed to a transformer"），
            // 按下时那层变暗就是这么来的。`imageColorTransformer` 收到的正是**改过之后**的颜色，
            // 直接返回我们的颜色 = 把系统这次的调整丢掉。
            //
            // ⚠️ 这里捕获的是颜色**值**，不是 `self`：transformer 归 configuration 持有，
            // configuration 归按钮自己持有，捕获 self 就和按钮成环了。
            let color = self.iconColor
            // 禁用时交回系统 —— 要变淡，用户才看得出「点不了」。
            updated.imageColorTransformer = button.isEnabled
                ? UIConfigurationColorTransformer { _ in color }
                : nil

            button.configuration = updated
        }

        // `icon` / `iconColor` 是在 `super.init` **之前**赋的 —— 那一下属性观察器不触发，
        // 所以初始这一次要自己请一遍（`updateConfiguration` 头文件写明不许直接调）。
        setNeedsUpdateConfiguration()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 缩放实现

    /// 把**图标**缩到指定倍数（不是把整个按钮缩）。
    ///
    /// 🔴 缩 `imageView` 而不是 `self`：按钮有底圈时，底圈要**不动**，只有图标缩进去
    /// （Apple Music 就是这么做的）。
    ///
    /// 🔴 **动画挂在 layer 上，`imageView` 自己的 `transform` 从头到尾不碰（保持原样）。**
    /// 这个按钮的内容归 `UIButton.Configuration` 管 —— 按下时系统会把内容重摆一遍，
    /// 一重摆，给视图设的 transform 就被冲掉、图标弹回原大（实测：长按会先放大一下）。
    /// 动画挂在 layer 上、视图的大小属性不动，系统怎么摆都碰不到它。
    ///
    /// 曲线显式写**缓入缓出**：`UIView.animate` 不指定曲线就是这个，
    /// 但 CA 的默认是**线性**（写线性会显得生硬）。
    ///
    /// 「减少动态效果」开着时把时长压成 **0** —— 一步到位、不留过渡。
    override func applyScale(to factor: CGFloat, duration: TimeInterval) {
        guard let iconView = imageView else { return }

        let from = CATransform3DMakeScale(currentScale, currentScale, 1)
        let to = CATransform3DMakeScale(factor, factor, 1)
        currentScale = factor

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: to)
        animation.duration = UIAccessibility.isReduceMotionEnabled ? 0 : duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // 停在终值上，而且**不动 layer 的模型值** —— 系统重摆、按钮被复用时都不会拖着缩小的样子跑。
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        iconView.layer.add(animation, forKey: Self.scaleAnimationKey)
    }
}
