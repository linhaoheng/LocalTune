import UIKit

/// 两张图标来回换的按钮 —— 换图不是「换一张」，是**一张缩掉、一张长出来**。
///
/// 出处：Apple Music 播放键那套（`MusicApplication.framework/PlayPauseStop.ca`）。
/// 那边「换图」= 一叠图层的大小 / 透明度按弹簧动过去，两组弹簧参数见下面两个计算属性。
///
/// ⚠️ 和 `PressScaleButton` 是**两件事**：那个管「按下时缩」，这个管「换图时动」。
final class IconTransitionButton: UIButton {

    // MARK: - 弹簧

    /// 缩掉那一张用的弹簧 —— **快、硬**。缩没要利落，不能拖。
    private static var outgoingSpring: UISpringTimingParameters {
        makeSpring(mass: 1, stiffness: 845.74, damping: 58.1632)
    }

    /// 长出来那一张用的弹簧 —— **慢、软**。新的是"弹"出来的。
    private static var incomingSpring: UISpringTimingParameters {
        makeSpring(mass: 2, stiffness: 300, damping: 30)
    }

    /// 按弹簧常数造一组时序参数。
    ///
    /// ⚠️ `initialVelocity` **省不掉**：UIKit 只给 `dampingRatio` 和 `duration / bounce` 两版
    /// 配了「零速度」的简化写法，**`mass / stiffness / damping` 这一版没有** —— 不写编译不过。
    /// 给 `.zero` = 从静止开始，也正是头文件建议的取值（「You'll typically want to pass 0」）。
    private static func makeSpring(
        mass: CGFloat,
        stiffness: CGFloat,
        damping: CGFloat
    ) -> UISpringTimingParameters {
        UISpringTimingParameters(
            mass: mass,
            stiffness: stiffness,
            damping: damping,
            initialVelocity: .zero
        )
    }

    // MARK: - 常量

    /// 图标之外**至少**要留出的点击区边长 —— 手指头不会跟着图标一起变小。
    ///
    /// **`44`** 是系统自己那套导航栏按钮的点击区尺寸（也是人机界面指南给的最小值）。
    private static let minimumTapSide: CGFloat = 44

    /// 缩没的样子 —— 大小和透明度一起归零。
    private static let shrunk = CGAffineTransform(scaleX: 0, y: 0)

    // MARK: - 可调参数

    /// 图标颜色。只从 `AppColor` 取。
    ///
    /// ⚠️ 是 `let` —— 颜色本身是**动态色**，深浅一切系统自己换，
    /// 这里没有（也不需要）改颜色的时机。
    let iconColor: UIColor

    // MARK: - 状态

    /// 现在露着的是第几张。**出生时由调用方指定**（见 `init`）。
    ///
    /// ⚠️ **不给默认值**：按钮自己不知道当前该露哪张 —— 那个真相在调用方手里。
    /// 给个默认值就等于写死一张，初始态迟早跟真实状态脱节。
    private var currentIconIndex: Int

    // MARK: - 零件

    /// 每张图一个 —— 全叠在按钮正中，只有当前的露着。
    ///
    /// ⚠️ 用**自己的** `UIImageView`，不是 `UIButton` 那个 `imageView`：
    /// 按钮只有一个 `imageView`，装不下两张要同时动的图。
    private let iconViews: [UIImageView]

    // MARK: - 建立

    /// - Parameters:
    ///   - icons: 要来回换的图标，**至少两张**。
    ///   - initialIndex: **出生时露哪一张**。不给默认值 —— 按钮不知道当前该露哪张，
    ///     那个真相在调用方手里；给个默认值就等于写死一张，初始态迟早跟真实状态脱节。
    ///   - iconColor: 图标颜色。
    ///
    /// 图标多大由图标自己带 —— 要多大就在建 `UIImage` 时
    /// `applyingSymbolConfiguration` 定好，这里不再多一个尺寸参数。
    init(icons: [UIImage], initialIndex: Int, iconColor: UIColor = AppColor.title) {
        self.iconColor = iconColor
        self.currentIconIndex = initialIndex
        iconViews = icons.map { image in
            let view = UIImageView(image: image.withRenderingMode(.alwaysTemplate))
            view.contentMode = .center
            view.tintColor = iconColor
            return view
        }
        super.init(frame: .zero)

        if icons.count < 2 {
            assertionFailure("换图按钮至少要两张图 —— 一张图没得换")
        }
        if !icons.indices.contains(initialIndex) {
            assertionFailure("初始下标越界 —— 按钮会一张图都不露")
        }
        setupIconViews()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 换图

    /// 换成第几张。
    func showIcon(at index: Int) {
        guard iconViews.indices.contains(index), index != currentIconIndex else { return }

        let outgoing = iconViews[currentIconIndex]
        let incoming = iconViews[index]
        // 模型值**立刻**就是新值 —— 动画只是屏幕上的过渡。
        currentIconIndex = index

        guard !UIAccessibility.isReduceMotionEnabled else {
            // 「减少动态效果」开着就一步到位，不做动画。
            outgoing.transform = Self.shrunk
            outgoing.alpha = 0
            incoming.transform = .identity
            incoming.alpha = 1
            return
        }

        // ⚠️ 进来的那张要**先摆成缩没的样子**再动 —— 不然它从"原位"开始长，
        // 看起来是闪了一下，不是"弹出来"。
        incoming.transform = Self.shrunk
        incoming.alpha = 0

        animate(outgoing, to: Self.shrunk, alpha: 0, spring: Self.outgoingSpring)
        animate(incoming, to: .identity, alpha: 1, spring: Self.incomingSpring)
    }

    // MARK: - 尺寸

    /// 按钮的固有尺寸 = **图标尺寸和最小点击区，取大的那个**。
    ///
    /// ⚠️ 必须给：这个类不用 `UIButton` 自己的 `image`（图是自定义的子视图），
    /// 不给的话固有尺寸是「没有」，`UIBarButtonItem(customView:)` 会把它摆成 0 大小 ——
    /// 看不见、也点不到。
    override var intrinsicContentSize: CGSize {
        let widest = iconViews.map(\.intrinsicContentSize.width).max() ?? 0
        let tallest = iconViews.map(\.intrinsicContentSize.height).max() ?? 0
        return CGSize(
            width: max(widest, Self.minimumTapSide),
            height: max(tallest, Self.minimumTapSide)
        )
    }

    // MARK: - 私有 · 建立

    private func setupIconViews() {
        for (index, view) in iconViews.enumerated() {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: centerXAnchor),
                view.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])

            // 初始状态：第 0 张露着，其余全缩没。
            let isCurrent = index == currentIconIndex
            view.transform = isCurrent ? .identity : Self.shrunk
            view.alpha = isCurrent ? 1 : 0
        }
    }

    // MARK: - 私有 · 动画

    /// 把一张图动到指定的样子。
    ///
    /// ⚠️ 时长以弹簧为准 —— `UISpringTimingParameters` 自己会按弹簧常数算出 duration
    /// （头文件原话：duration is computed assuming a small settling oscillation），
    /// 这里的 `duration` 传 0 只是占位。
    private func animate(
        _ view: UIView,
        to transform: CGAffineTransform,
        alpha: CGFloat,
        spring: UISpringTimingParameters
    ) {
        let animator = UIViewPropertyAnimator(duration: 0, timingParameters: spring)
        animator.addAnimations {
            view.transform = transform
            view.alpha = alpha
        }
        animator.startAnimation()
    }
}
