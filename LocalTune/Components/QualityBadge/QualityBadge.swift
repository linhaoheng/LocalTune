import SnapKit
import UIKit

/// 音质徽章 —— 一枚**填充渐变 ＋ 白字**的小胶囊：`SD` / `HQ` / `SQ` / `HR`。
///
/// 🔴 **一份，列表行和播放页共用**（`Components/` 就是放"多个页面都用的零件"的那一层）。
/// ⚠️ 别做成**两套实现** —— 列表行一枚、播放页自己又画一枚；圆角 / 内边距 / 白字 / 居中
/// **逐字一样**，**只差字号（列表 8 粗、播放页 9 粗）**。同一件东西写两遍，改一处忘一处是迟早的事。
///
/// 🔴 **它只画，不判**：给它一个档位，它取色、写字。「这首歌是哪一档」**不在这儿** ——
/// 那是 `Track.audioQualityLevel`（纯函数，吃已经存进库的字段）。
///
/// ⚠️ **色值和字号都不在这个文件里**：色在 `AppColor.QualityBadge`、
/// 字号由**建它的人**给（`AppFont.nowPlayingQualityBadge` / `AppFont.songRowQualityBadge`）
/// —— 宪法第二节：页面 / 组件里不写死色值和字号。
final class QualityBadge: UIView {

    /// 这一枚徽章自己的尺寸。
    ///
    /// ⚠️ 先放这儿、**不往 `AppMetrics` 放**：它们只有这一个组件用
    ///（`AppMetrics` 收的是"页面版式上那一批数"，这是组件内部的构造细节）。
    private enum Metrics {

        /// 圆角 **2**。
        static let cornerRadius: CGFloat = 2

        /// 字外面那圈内边距 —— **上下 1 · 左右 3**（`(1, 3, 1, 3)`）。
        ///
        /// ⚠️ 它同时决定了徽章**怎么长**：宽 = 字宽 + 6、高 = 行高 + 2 —— 没有写死的尺寸。
        static let textInsets = UIEdgeInsets(top: 1, left: 3, bottom: 1, right: 3)
    }

    /// 渐变**就是这一层的底**：挂在这一层的最下面，跟着视图自己的 bounds 走。
    private let gradientLayer = CAGradientLayer()

    private let textLabel = UILabel()

    /// 这一枚徽章用哪一号字 —— **建出来就定死**。
    ///
    /// 🔴 **为什么是构造参数、不是能改的属性**：字号两处不一样（列表 8 粗、播放页 9 粗，
    /// ），但它**建出来之后不会再变**。做成 `var` 就等于留了个口子 ——
    /// 哪天有人在别处改一下，两处的大小就悄悄不一样了，而这种事不该有第二个地方能决定。
    ///
    /// ⚠️ 也不在这儿给默认值：默认值必然偏向某一页，另一页就变成"忘了传"看不出来。
    let font: UIFont

    init(font: UIFont) {
        self.font = font
        super.init(frame: .zero)
        buildSubviews()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    /// 渐变层**不归自动布局管**，大小得自己跟上视图 —— 这一行是它唯一的同步点。
    ///
    /// ⚠️ 不用 `layerClass` 把渐变顶替成 `layer`：那样每取一次都得 `as?` 一次，
    /// 而 `as?` 取不到时**没有合理的退路** —— 属性里不能写 `as!`，
    /// 返回一个新建的层又等于静默地什么都不画。挂成子层就没有这个岔路口。
    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    /// 徽章**自己知道自己多大**：字 ＋ 那圈内边距。
    ///
    /// 🔴 **必须有它**：容器（`UIStackView` 这类）是**按内容尺寸**给子视图分地方的 ——
    /// 一个没有内容尺寸的裸 `UIView` 放进去，宽度就没有主张，那一行会跟着错位。
    /// 拿约束手工摆的时候不需要这一条；我们要能放进任何容器，就需要。
    override var intrinsicContentSize: CGSize {
        let text = textLabel.intrinsicContentSize
        return CGSize(
            width: text.width + Metrics.textInsets.left + Metrics.textInsets.right,
            height: text.height + Metrics.textInsets.top + Metrics.textInsets.bottom
        )
    }

    // MARK: - 对外

    /// 换成某一档：取它那对渐变端色和那两个字。
    func show(_ level: AudioQualityLevel) {
        let gradient = Self.gradient(for: level)
        gradientLayer.colors = [gradient.start.cgColor, gradient.end.cgColor]
        textLabel.text = level.text
        // 字换了 ⇒ 「自己多大」要重算（"SD" 和 "HQ" 不一样宽）。
        invalidateIntrinsicContentSize()
    }

    // MARK: - 装配

    private func buildSubviews() {
        layer.cornerRadius = Metrics.cornerRadius
        // 圆角靠这一条把渐变层一起裁掉 —— 渐变层自己不用再设一遍圆角。
        clipsToBounds = true

        // 横向渐变（起在左、止在右）。
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.insertSublayer(gradientLayer, at: 0)

        textLabel.font = font
        textLabel.textColor = AppColor.onAccent
        textLabel.textAlignment = .center
        addSubview(textLabel)

        // 🔴 **徽章多大就多大**：它跟别的东西横着排在一起时，该伸缩的是**旁边那行文字**，
        // 不是它 —— 一行放不下时让文字去截断（那是它自己的 `lineBreakMode`）。
        // ⚠️ 两个都要写：不写的话两边都是默认值（拉伸 250 / 压缩 750），
        // 系统随便挑一个拉或压 —— 挑到谁身上不确定。
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        // 里层那两个字同理（徽章真被压时，先撑不住的不该是它）。
        textLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // 徽章多大**由字撑出来**：字 ＋ 那圈内边距。
        textLabel.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(Metrics.textInsets)
        }
    }

    /// 档位 → 那对渐变端色。
    ///
    /// ⚠️ **这层映射只能待在组件里**：`AppColor` 在 `Core` 层，宪法第一节写着 Core
    /// 不许出现业务名 —— 它不认识 `AudioQualityLevel`（那个在 `Data` 层）。
    /// 所以 `AppColor` 只出四个色对，由组件把色对和档位对上。
    ///
    /// ⚠️ 写成 `switch` 而不是查表：档位将来多一档，这里**编译就过不去**，
    /// 不会静默地少一个颜色。
    private static func gradient(for level: AudioQualityLevel) -> (start: UIColor, end: UIColor) {
        switch level {
        case .sd: AppColor.QualityBadge.sd
        case .hq: AppColor.QualityBadge.hq
        case .sq: AppColor.QualityBadge.sq
        case .hr: AppColor.QualityBadge.hr
        }
    }
}
