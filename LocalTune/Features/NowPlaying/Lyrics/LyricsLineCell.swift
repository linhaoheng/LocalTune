import SnapKit
import UIKit

/// 歌词列表里的一行 —— **正文** ＋ 行下可选的**附属字**。
///
/// ## 三件事
///
/// - **正文**：普通行 `base × 0.9`（常规体、白 α0.5），当前行 `base`（粗体、纯白）。
///   字号从外面给的 `baseFontSize` 算（= `AppMetrics.nowPlayingLyricsFontSize` 的**出厂值**，
///   用户可在设置面板里把它改成 16…36，见 `LyricsAppearance`），这里不写死。
/// - **对齐**：正文与附属字**同一档**，由外面给的 `alignment` 决定（左 / 中 / 右）——
///   值层那个 UIKit-free 的 `LyricsAlignment` 到这儿才翻成 `NSTextAlignment`。
/// - **附属字**：内嵌歌词里跟原文写在**同一个时间戳**的那几行（译文 / 注音），一条一行、
///   `base × 0.65` 中等体、白 α0.4。**文件里没有就没有**，我们不补、不翻。
/// - **行内换行行距 6**（`AppMetrics.nowPlayingLyricsInnerLineSpacing`）——
///   ⚠️ 那是"**这一行字自己折行**"的行距；跟**列表**里行与行的 12
///   （`AppMetrics.nowPlayingLyricsLineSpacing`，走 `UICollectionViewFlowLayout`）是两回事，别混。
///
/// ## 高度由**外面**算
///
/// `height(for:…)` 跟这里搭出来的约束必须是**同一套算法**（正文高 ＋ 间隙 ＋ 每条附属字高），
/// 两处得一起改。没走"内容自适应"（self-sizing）不是偷懒：歌词行高错一点会**累积成整篇错位**，
/// 宁可显式算、让"高度是从哪来的"看得见（`LyricsFollowCoordinator` 也是显式测高）。
///
/// ⚠️ **逐字卡拉OK（4d）在正文上又叠了一层**：`textLabel` 是"没唱的样子"，
/// `highlightLabel` 是"唱了的样子"，两层**同文本同 font**、只换颜色 ⇒ 完全重合；
/// 顶字被 **一张合成 mask**（每字各贡献一份，见 `KaraokeMaskRenderer.strokes`）按进度揭开。
/// **只有"当前行 且 有逐字 且 在播"才有这一层**（判据在 `KaraokeSweepPolicy.runState`）。
/// 详见 `播放页歌词.md` §M.7。
final class LyricsLineCell: UICollectionViewCell {

    static let reuseID = "LyricsLineCell"

    /// 正文（**底层**：没唱的那一档颜色）。
    private let textLabel = UILabel()

    /// 正文（**顶层**：唱了的那一档颜色）—— 四边贴住 `textLabel`，露多少由 `maskHost` 决定。
    private let highlightLabel = UILabel()

    /// 顶字的遮罩 —— `contents` 每帧换成**合成好的一张** mask 图（每字各画一份）。
    /// 🔴 不用 lit + 唯一 sweep：相邻两字会同时半亮（窗口重叠），单槽会把上一字尾巴挤掉。
    private let maskHost = CALayer()

    /// 附属字那一摞（一条一行）。
    private let companionStack = UIStackView()

    /// 附属字的 label **池**：按需往下加，只增不减 —— 列表来回滚时不用反复建视图。
    private var companionLabels: [UILabel] = []

    /// 正文 ＋ 附属字那一摞。
    private let stack = UIStackView()

    /// 逐字矩形怎么排 / mask 怎么合成 —— **每个 cell 一个**。
    private let karaokeRenderer = KaraokeMaskRenderer()

    // MARK: - 逐字状态

    private var karaokeSegments: [KaraokeSweepPolicy.Segment]?
    private var karaokeText: String?
    private var karaokeFont: UIFont?
    private var karaokeParagraph: NSParagraphStyle?

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildSubviews()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        textLabel.attributedText = nil
        // 复用前把逐字那套整个收掉 —— 不然上一行的矩形 / 遮罩会跟着这行一起被复用出去。
        clearKaraoke()
        // ⚠️ 这里传哪个对齐都一样：正文已经被清空、附属字被清成空数组 ⇒ 一个字都不画（只把池收起来）。
        applyCompanions([], baseFontSize: AppMetrics.nowPlayingLyricsFontSize, alignment: .center)
    }

    // MARK: - 对外

    /// 摆一行。`isCurrent` 决定正文用哪一档（粗体纯白 / 常规半透明白）；
    /// `alignment` 是用户选的对齐（正文与附属字**同一档**）。
    ///
    /// 🔴 **当前行且有逐字**时，正文变成**两层**：底字用"没唱"那一档（`overlayTint`，
    /// 跟普通行同色），顶字才是"唱了"的纯白 —— 扫光就是顶字被逐词揭开。
    func show(
        line: LyricsLine, isCurrent: Bool, baseFontSize: CGFloat, alignment: LyricsAlignment
    ) {
        let textAlignment = Self.textAlignment(for: alignment)
        let font = AppFont.lyricsLine(baseSize: baseFontSize, isCurrent: isCurrent)

        let segments = isCurrent ? KaraokeSweepPolicy.segments(of: line) : []
        let isKaraoke = !segments.isEmpty

        let baseColor = (isCurrent && !isKaraoke) ? AppColor.nowPlayingSolid : AppColor.overlayTint
        textLabel.attributedText = Self.attributed(
            line.text, font: font, color: baseColor, alignment: textAlignment
        )

        if isKaraoke {
            karaokeSegments = segments
            karaokeText = line.text
            karaokeFont = font
            karaokeParagraph = Self.paragraph(alignment: textAlignment)
            karaokeRenderer.invalidate()
            highlightLabel.attributedText = Self.attributed(
                line.text, font: font, color: AppColor.nowPlayingSolid, alignment: textAlignment
            )
        } else {
            clearKaraoke()
        }

        applyCompanions(
            line.companionTexts, baseFontSize: baseFontSize, alignment: textAlignment
        )
    }

    /// 这一行**现在扫到哪儿** —— 列表每一帧调一次（`time` 是**播放时间**，不是墙上时间）。
    ///
    /// 不在这儿算"该不该跑"：那是 `KaraokeSweepPolicy.runState` 的事，由列表判。
    func renderKaraoke(at time: TimeInterval) {
        guard let segments = karaokeSegments, !segments.isEmpty,
              let text = karaokeText, let font = karaokeFont, let paragraph = karaokeParagraph
        else { return }

        let size = highlightLabel.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let rects = karaokeRenderer.rects(
            for: segments, text: text, font: font, paragraph: paragraph, width: textLabel.bounds.width
        )
        guard rects.count == segments.count else { return }

        let strokes = KaraokeMaskRenderer.strokes(segments: segments, rects: rects, at: time)
        let image = KaraokeMaskRenderer.composeMaskImage(
            size: size,
            scale: traitCollection.displayScale,
            strokes: strokes
        )

        // 🔴 关掉隐式动画 —— 否则每换一次 `contents` 会拿到 0.25s 默认动画，掩码在"追"着唱。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        highlightLabel.isHidden = false
        if highlightLabel.layer.mask !== maskHost { highlightLabel.layer.mask = maskHost }
        maskHost.frame = highlightLabel.bounds
        maskHost.contentsScale = traitCollection.displayScale
        maskHost.contents = image
    }

    /// 把逐字那一层整个收掉（非当前行 / 换行表 / 换字号 / 复用前）。
    func clearKaraoke() {
        karaokeSegments = nil
        karaokeText = nil
        karaokeFont = nil
        karaokeParagraph = nil
        karaokeRenderer.invalidate()
        highlightLabel.isHidden = true
        highlightLabel.layer.mask = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskHost.contents = nil
        CATransaction.commit()
    }

    /// 这一行摆出来要多高 —— 跟下面的约束是同一套算法（见类型顶上那段）。
    ///
    /// `width` 是列表给的可用宽（已经扣掉左右边距）。
    static func height(
        for line: LyricsLine, isCurrent: Bool, width: CGFloat, baseFontSize: CGFloat
    ) -> CGFloat {
        guard width > 0 else { return 0 }

        var total = textHeight(
            line.text,
            font: AppFont.lyricsLine(baseSize: baseFontSize, isCurrent: isCurrent),
            width: width
        )
        let companions = line.companionTexts
        if !companions.isEmpty {
            let font = AppFont.lyricsCompanion(baseSize: baseFontSize)
            // 正文与附属字那一摞之间、以及摞里每条之间，都是同一个间隙。
            for text in companions {
                total += AppMetrics.nowPlayingLyricsCompanionGap
                total += textHeight(text, font: font, width: width)
            }
        }
        return ceil(total)
    }

    // MARK: - 装配

    private func buildSubviews() {
        contentView.backgroundColor = .clear
        backgroundColor = .clear

        textLabel.numberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping
        // ⚠️ 这里**不设** `textAlignment`：对齐写在正文那份 `NSAttributedString` 的段落样式里
        // （`show(line:isCurrent:baseFontSize:alignment:)`）—— 属性串上的段落样式**优先**，
        // 在这儿再设一次就是"同一件事两处记着"，改一处忘一处。

        companionStack.axis = .vertical
        companionStack.spacing = AppMetrics.nowPlayingLyricsCompanionGap
        companionStack.isHidden = true

        stack.axis = .vertical
        stack.spacing = AppMetrics.nowPlayingLyricsCompanionGap
        stack.addArrangedSubview(textLabel)
        stack.addArrangedSubview(companionStack)
        contentView.addSubview(stack)

        // 顶字：**四边贴住正文**（约束可以跨层级 —— 它俩最终都落在 `contentView` 里）。
        //
        // 🔴 用"贴 `textLabel`"而不是"另起一层容器"：`textLabel` 继续当 `stack` 的排列子视图，
        // `height(for:)` 那条**尺寸链一个字都不用改**（它跟这儿的约束必须是同一套算法，见类型顶上那段）。
        // ⚠️ 加在 `stack` **之后** ⇒ 它压在正文上面。
        highlightLabel.numberOfLines = 0
        highlightLabel.lineBreakMode = .byWordWrapping
        highlightLabel.isHidden = true
        contentView.addSubview(highlightLabel)

        // mask 只挂一个层；图由 `renderKaraoke` 写进 `contents`。
        maskHost.contentsGravity = .resize

        stack.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            // 🔴 **只钉上边，下边是 `<=`** —— 行高由 `height(for:…)` 从外面定（`sizeForItemAt`）。
            // 下边钉死的话，算出来的高比实际内容多出几像素时，`UIStackView` 会把最后一条
            // **拉高**去填满（`.fill` 的默认行为），字就被扯变形了。
            make.bottom.lessThanOrEqualToSuperview()
        }

        highlightLabel.snp.makeConstraints { make in
            make.edges.equalTo(textLabel)
        }
    }

    /// 顶字的遮罩跟着正文的尺寸走 —— 字号 / 对齐 / 转屏一变，下一帧 `renderKaraoke` 会重画。
    ///
    /// ⚠️ 这里**只贴 `frame`**：`contents` 是"唱到哪"的事，归 `renderKaraoke(at:)`。
    override func layoutSubviews() {
        super.layoutSubviews()
        guard highlightLabel.layer.mask != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskHost.frame = highlightLabel.bounds
        CATransaction.commit()
    }

    /// 附属字：不够就往下加 label，多出来的藏起来（池只增不减）。
    private func applyCompanions(
        _ texts: [String], baseFontSize: CGFloat, alignment: NSTextAlignment
    ) {
        while companionLabels.count < texts.count {
            let label = Self.makeCompanionLabel()
            companionStack.addArrangedSubview(label)
            companionLabels.append(label)
        }
        for (index, label) in companionLabels.enumerated() {
            guard index < texts.count else {
                label.isHidden = true
                label.attributedText = nil
                continue
            }
            label.isHidden = false
            label.attributedText = Self.attributed(
                texts[index],
                font: AppFont.lyricsCompanion(baseSize: baseFontSize),
                color: AppColor.nowPlayingLyricsSecondary,
                alignment: alignment
            )
        }
        companionStack.isHidden = texts.isEmpty
    }

    // MARK: - 排版

    /// 值层的对齐 → UIKit 那一档。
    ///
    /// 🔴 **只在这一个地方翻**：`LyricsAlignment` 是 UIKit-free 的值类型（设置层要用它），
    /// 到这里才落成 `NSTextAlignment` —— 两边别各翻一次。
    private static func textAlignment(for alignment: LyricsAlignment) -> NSTextAlignment {
        switch alignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    /// 一行文字的段落样式 —— 行内换行行距 ＋ 对齐（见类型顶上那段的区分）。
    ///
    /// ⚠️ **不加 `private`**：`KaraokeMaskRenderer` 的矩形必须跟正文**同一份**段落样式排出来，
    /// 单测也要拿它当基准（`KaraokeMaskRendererTests`）。收成 `private` 就逼着别处再写一份
    /// —— 那正是"同一件事两处记着"。
    static func paragraph(alignment: NSTextAlignment) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = AppMetrics.nowPlayingLyricsInnerLineSpacing
        paragraph.alignment = alignment
        return paragraph
    }

    private static func attributed(
        _ text: String, font: UIFont, color: UIColor, alignment: NSTextAlignment
    ) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph(alignment: alignment)
        ])
    }

    /// 一段文字在给定宽度下占多高（跟上面那份段落样式**同一套构造** —— 用的是同一个 `paragraph`）。
    ///
    /// ⚠️ **这里传 `.natural` 就够了**：对齐不影响 `boundingRect` 的高度（它只决定字往哪边靠），
    /// 所以不必把 `alignment` 一路传进 `height(for:…)`（那里也确实没有它这一项）。
    /// 传 `.natural` 而不是省掉这次构造，是为了让**行距那一项只有一个出处**。
    private static func textHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph(alignment: .natural)],
            context: nil
        )
        return ceil(rect.height)
    }

    private static func makeCompanionLabel() -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }
}
