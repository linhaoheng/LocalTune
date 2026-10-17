import UIKit

/// 按下会缩一下的**实心文字按钮** —— 有底色、有圆角，按下去**整块缩**。
///
/// 手感和那个图标按钮（`PressScaleButton`）**是同一套** —— 时长直接读同一份
/// `AppMetrics.pressDownDuration` / `pressUpDuration`（手感是一件事，只有一个出处）。
/// **倍数不一样**，为什么见 `pressScale`。
///
/// 🔴 **为什么单写一个、不把图标那个改成通用件**：图标按钮缩的是"按钮里的**图标**"、
/// 底圈纹丝不动，那是它的**功能**不是可选项；
/// 而这类按钮没有"图标 / 底圈"的分家，它就是一整块 —— **整块缩**才对。
/// 两边"缩谁"根本不同，硬合成一个类，只会把那个已经调好的按钮改复杂。
///
/// ⚠️ "整块缩"怎么缩（动自己的 `transform`）在基类里，这里不用再写一遍。
final class PressScaleActionButton: PressableButton {

    // MARK: - 常量

    /// 圆角。
    ///
    /// **不是令牌**：Radix 五档圆角里没有 10（small 那档最大 12、large 那档最小 4.5），凑不到，
    /// 所以只能显式写在这儿。10 是"四个角看着是方的、又不扎手"的那一档。
    private static let cornerRadius: CGFloat = 10

    /// 文字四周留多少 —— 按钮才不像一个紧贴着字的标签。
    private static let contentInset: CGFloat = AppMetrics.s15

    /// 按钮上那行字。**建好之后还能改** —— 用它拼装界面时（比如空状态先建块、后填文案）
    /// 是按需要设进去的。
    var title: String? {
        get { configuration?.title }
        set { configuration?.title = newValue }
    }

    // MARK: - 零件

    /// 底色 / 字色。
    ///
    /// 存下来是为了"每次状态一变就把颜色摆回去"（见 `pinColorsAgainstHighlight`）——
    /// 系统按下时会把这两个色调一调再拿出来用，那层调整就是"高亮"。
    private let fillColor: UIColor
    private let titleColor: UIColor

    // MARK: - 建立

    /// - Parameters:
    ///   - title: 按钮上的字。留空也行，之后从 `title` 设。
    ///   - background: 底色。
    ///   - foreground: 字的颜色。
    init(
        title: String = "",
        background: UIColor = AppColor.accent,
        foreground: UIColor = AppColor.onAccent
    ) {
        fillColor = background
        titleColor = foreground
        super.init(frame: .zero)

        // 实心按钮缩得比图标按钮收敛（0.9 vs 0.8）：它大得多，缩同样比例边上位移太夸张。
        pressScale = 0.9

        // ⚠️ 外观走 `UIButton.Configuration`，**不用 `contentEdgeInsets`** ——
        // 后者从 iOS 15 起废弃了，而且圆角也没地方设。
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.baseBackgroundColor = background
        configuration.baseForegroundColor = foreground
        // 告诉系统"圆角我说了算"：不写这行，系统会按按钮高度自己算一个（`dynamic`），
        // 下面设的 `cornerRadius` 就不作数了。
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = Self.cornerRadius
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: Self.contentInset,
            leading: Self.contentInset,
            bottom: Self.contentInset,
            trailing: Self.contentInset
        )
        // 标题字号**不自己定** —— 交给系统那套按钮规格：`UIButton.Configuration` 会给标题
        // 一个和控件其它部分协调的字号，自己定一个数反而会跟按钮的边距、圆角脱节。
        // 好处是它自己跟着系统文字大小走，不用我们再挂一次缩放。
        self.configuration = configuration

        // 按下时别叠系统那层变暗 —— 见基类里那段（字色和图标色也一起钉）。
        pinColorsAgainstHighlight(fill: fillColor, text: titleColor)
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }
}
