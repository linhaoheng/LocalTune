import UIKit

/// 按下会缩放的按钮基类 —— 把"按下缩 / 抬起弹"的事件接线统一在这儿。
///
/// 两个子类（图标按钮 `PressScaleButton`、实心文字按钮 `PressScaleActionButton`）
/// 缩的东西不同（一个挂图标 layer、一个动自身 transform），但**按下哪些事件触发缩、
/// 哪些事件触发弹回**是同一套 —— 所以接线在基类，子类只实现 `applyScale`。
class PressableButton: UIButton {

    /// 按下时缩到的倍数。子类按自己的手感设默认值。
    var pressScale: CGFloat = 0.9

    /// 缩放总开关 —— 工具栏里只当点击热区用的按钮会关掉它。
    var isPressScaleEnabled = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        installPressEvents()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    /// 装事件。init 已经调过，子类不用再调。
    ///
    /// ⚠️ 按钮禁用时 `UIControl` **不发事件**，所以这里不用判 `isEnabled`。
    func installPressEvents() {
        addTarget(self, action: #selector(handlePressDown), for: .touchDown)
        addTarget(self, action: #selector(handlePressDown), for: .touchDragEnter)
        addTarget(
            self,
            action: #selector(handlePressUp),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )
    }

    /// 把视图真的缩下去。
    ///
    /// 默认就是**缩按钮自己**（`transform`）—— "整块缩"的那几个子类不用再各写一遍。
    ///
    /// ⚠️ 用不着图标按钮（`PressScaleButton`）那边"挂到图层上"那套：那套是为了躲开
    /// "系统按下时会重摆按钮内容、把缩放冲掉"；按钮**自身**的 `transform` 系统不碰，
    /// 所以最普通的做法就够。**缩的不是自己**的子类才需要重写它。
    ///
    /// - Parameters:
    ///   - factor: 目标倍数（按下时是 `pressScale`，抬起时是 `1`）。
    ///   - duration: 动画时长（按下 / 抬起两个数在 `AppMetrics`）。
    func applyScale(to factor: CGFloat, duration: TimeInterval) {
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : duration,
            delay: 0,
            // `.beginFromCurrentState`：连着快按两下时，从"现在缩到哪儿"接着动，不跳回起点。
            // `.allowUserInteraction`：动画还没走完也收得到触摸，不然连按第二下会丢。
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut],
            animations: { self.transform = CGAffineTransform(scaleX: factor, y: factor) }
        )
    }

    // MARK: - 按下时不要系统那层"变暗"

    /// 把底色 / 字色 / 图标色**钉住** —— 按下时不再叠一层系统的变暗，按下去只靠缩放说话。
    ///
    /// 🔴 那层变暗是系统给的：按下时它会把 `baseBackgroundColor` / `baseForegroundColor`
    /// **调一调再拿出来用**（SDK 原话："This color may be modified before being passed to
    /// a transformer"）。要它别出现，只能每次状态一变就把颜色换回我们自己的。
    ///
    /// ⚠️ 三处都要钉：只钉底色的话，按下去字和图标还会各自暗一下 ——
    /// 一块东西上三种深浅，看着像没对齐。
    ///
    /// ⚠️ **禁用时把变换器撤掉、交回系统** —— 那会儿正需要变淡，
    /// 用户才看得出"这个点不了"。
    ///
    /// ⚠️ 变换器里**不要捕获 `self`**：它归 configuration 持有、configuration 归按钮自己持有，
    /// 捕获 self 就和按钮成环了。所以颜色按值传进来、先在闭包外面存成局部常量。
    ///
    /// - Parameters:
    ///   - fill: 底色。
    ///   - text: 字色，同时也是图标色。
    ///   - font: 字号的来源。不传就用 `UIButton.Configuration` 给的那一档
    ///     —— 传的是**取值动作**不是字体本身，系统文字大小一变它才会跟着重取。
    func pinColorsAgainstHighlight(fill: UIColor, text: UIColor, font: (() -> UIFont)? = nil) {
        configurationUpdateHandler = { button in
            guard var updated = button.configuration else { return }
            let isOn = button.isEnabled

            updated.background.backgroundColorTransformer = isOn
                ? UIConfigurationColorTransformer { _ in fill }
                : nil
            updated.imageColorTransformer = isOn
                ? UIConfigurationColorTransformer { _ in text }
                : nil
            updated.titleTextAttributesTransformer = isOn
                ? UIConfigurationTextAttributesTransformer { incoming in
                    var outgoing = incoming
                    outgoing.foregroundColor = text
                    if let font { outgoing.font = font() }
                    return outgoing
                }
                : nil

            button.configuration = updated
        }
        // 颜色是在 `super.init` **之前**赋的，那一下不会触发上面这段处理；
        // 初始这一次自己请一遍（`updateConfiguration` 头文件写明不许直接调）。
        setNeedsUpdateConfiguration()
    }

    // MARK: - 事件

    @objc private func handlePressDown() {
        guard isPressScaleEnabled else { return }
        applyScale(to: pressScale, duration: AppMetrics.pressDownDuration)
    }

    /// ⚠️ 抬起时**不判** `isPressScaleEnabled`：万一按下之后它被关掉，也得把大小复位，
    /// 不然按钮会卡在缩小的样子上。
    @objc private func handlePressUp() {
        applyScale(to: 1, duration: AppMetrics.pressUpDuration)
    }
}
