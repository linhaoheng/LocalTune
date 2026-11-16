import SnapKit
import UIKit

/// 歌词列表里的一行 —— **正文** ＋ 行下可选的**附属字**。
///
/// ## 三件事
///
/// - **正文**：**所有行同一个字号、同一个字重**（`AppFont.lyricsLine(baseSize:)`）。
///   当前行与普通行的差别**不在字体上** —— 字号一变整篇要重排，而歌词是跟着播放滚的。
///   差别只有两处：**画的时候的缩放**（普通行 `nowPlayingLyricsNormalScale`、当前行 1.0，
///   走 `transform` 所以不动占位）和**颜色**（当前行纯白、普通行白 α0.5）。
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

    /// 缩放与位移的**承载层** —— `transform` 只写它，**绝不写 `contentView`**。
    ///
    /// 🔴 为什么不能写 `contentView`：`UICollectionViewCell` 每次布局都会把
    /// `contentView.frame` 重新设成 `self.bounds`。而 `frame` 的 setter 在 `transform`
    /// 不是单位矩阵时是**反算 `bounds`** 的（`bounds.size = frame.size ÷ scale`）⇒
    /// 每布一次局，`contentView.bounds` 就被撑大 `1 ÷ scale` 倍（0.9 时是 11%）。
    /// 连锁反应有两条，正好是装机反馈的那两个毛病：
    /// 1. 宽度变 ⇒ `stack` 变宽 ⇒ `textLabel` 变宽 ⇒ `highlightLabel.bounds` 变宽 ⇒
    ///    上一帧按**旧宽度**画好的逐字 mask 被 `contentsGravity = .resize` 拉成新宽度
    ///    ⇒ **高亮块和字错位**（看着就是「唱到第 5 个字，切一行只剩第 3 个字」）；
    /// 2. 高度变 ⇒ `contentView.bounds.midY` 每帧都不一样 ⇒「以正文中心为锚」这个
    ///    前提不成立 ⇒ **锚点怎么调都不对**。
    ///
    /// 加这一层之后，cell 的布局系统碰不到它，`bounds` 恒等于 cell 的尺寸。
    private let scaledContainer = UIView()

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
        highlightLabel.attributedText = nil
        highlightLabel.alpha = 0
        line = nil
        // 交错滚动那段临时位移**必须**清掉：动画中这一格滚出屏、被复用到别的行上，
        // 带着位移过去就是「字飘到别人头上」。列表那边停动画时也会清，两处都要。
        cascadeOffset = 0
        normalScale = 1
        // 🔴 走 `applyTransform()`、**不直接写 `.identity`** —— `transform` 只留一个写者。
        // 位移 0 ＋ 缩放 1 ⇒ `(1 − scale)` 那一项归零，算出来必然是单位矩阵，效果一样。
        applyTransform()
        // 复用前把逐字那套整个收掉 —— 不然上一行的矩形 / 遮罩会跟着这行一起被复用出去。
        clearKaraoke()
        // ⚠️ 这里传哪个对齐都一样：正文已经被清空、附属字被清成空数组 ⇒ 一个字都不画（只把池收起来）。
        applyCompanions([], baseFontSize: AppMetrics.nowPlayingLyricsFontSize, alignment: .center)
    }

    // MARK: - 对外

    /// 交错滚动时这一格**临时**多出来的一段竖直位移（`0` ＝ 没有）。
    ///
    /// 🔴 **动的是 `scaledContainer`，不是 `stack`，更不是 `contentView`**：逐字高亮那一层
    /// （`highlightLabel`）是**贴在 `textLabel` 上、跟 `stack` 同级挂在 `scaledContainer` 下**的 ——
    /// 只动 `stack` 的话普通字在动、高亮层不动，看着就是「字还在上来的途中，
    /// 高亮已经在终点亮着了」。动 `scaledContainer` ⇒ 这一格的所有内容一起走，
    /// 将来往 cell 里再加层也不会漏；而 `contentView` 留给系统管（见 `scaledContainer` 那段）。
    ///
    /// ⚠️ 走的是 `transform` 不是约束：每帧改约束会触发重排，60 帧下来列表会抖。
    ///
    /// 🔴 **它只动位移** —— 缩放（`normalScale`）、明暗（`alpha`）、逐字层（mask）一个都不碰。
    /// 正因为这样它有两个用途：换行那一趟拿它当**动画起点**（旧状态原样留着，动画再推向
    /// `endTransition`），手滑打断时拿它清零（缩放和逐字层不受影响）。
    func setCascadeOffset(_ offset: CGFloat) {
        cascadeOffset = offset
        applyTransform()
    }

    // MARK: - 过渡（换行时把这一格从旧状态带到新状态）

    /// 这一格现在摆的是哪一行 —— `installKaraokeLayer()` 要靠它重算逐字层
    /// （换行那两行**不走 `show(...)`**，不重新配置文本）。
    private var line: LyricsLine?
    /// 当前字号 / 对齐 —— 同上。
    private var baseFontSize: CGFloat = AppMetrics.nowPlayingLyricsFontSize
    /// ⚠️ 名字带 `applied`：跟静态的 `textAlignment(for:)` 分开，免得读代码时分不清哪个是哪个。
    private var appliedTextAlignment: NSTextAlignment = .center

    /// 过渡的**终点**：位移归零、缩放与明暗到位。
    ///
    /// 列表把它放进 `UIViewPropertyAnimator` 的动画块里 —— 于是 `transform`（缩放＋位移）
    /// 和 `alpha` 由**同一个动画器**驱动，不会互相打断。`show(...)` 也调它（无动画）。
    func endTransition(isCurrent: Bool) {
        cascadeOffset = 0
        normalScale = isCurrent ? 1 : AppMetrics.nowPlayingLyricsNormalScale
        highlightLabel.alpha = isCurrent ? 1 : 0
        applyTransform()
    }

    /// 装 / 卸逐字那一层（顶字的 mask）。
    ///
    /// ⚠️ 不碰 `highlightLabel.alpha` —— 顶字露多少归 `endTransition` 管。
    /// `clearKaraoke()` 会把 mask 摘掉 ⇒ 顶字整行显示，正是"当前行但没有逐字"要的样子。
    private func applyKaraokeLayer(isCurrent: Bool) {
        guard let line else {
            clearKaraoke()
            return
        }
        let segments = isCurrent ? KaraokeSweepPolicy.segments(of: line) : []
        guard !segments.isEmpty else {
            clearKaraoke()
            return
        }
        karaokeSegments = segments
        karaokeText = line.text
        karaokeFont = AppFont.lyricsLine(baseSize: baseFontSize)
        karaokeParagraph = Self.paragraph(alignment: appliedTextAlignment)
        karaokeRenderer.invalidate()
    }

    /// 换行时给**新的当前行**装上逐字层 —— 不参与动画（mask 没有可插值的量）。
    ///
    /// 🔴 **只装、不拆。** 普通行身上那一层必须**留着**：淡出时要淡的是
    /// 「原来亮到哪儿」的那一块，不是「整行」。拆下归 `show(...)`（这一格要装新内容了）
    /// 和 `prepareForReuse`（被复用到别的行上）。
    func installKaraokeLayer() {
        applyKaraokeLayer(isCurrent: true)
    }

    // MARK: - 变换（缩放 ＋ 临时位移）

    /// 这一趟交错滚动的临时位移 —— 只有换行那几百毫秒不是 0。
    private var cascadeOffset: CGFloat = 0

    /// 这一行**画出来**缩到多少：当前行 1.0，普通行 `nowPlayingLyricsNormalScale`。
    private var normalScale: CGFloat = 1

    /// 缩放**锚在哪儿** —— 跟着对齐走。不这么做的话，0.9 的缩放会把左对齐的字
    /// 整体往中间收 5% 宽，看着像「缩进」而不是「小一号」。
    private var scaleAlignment: LyricsAlignment = .center

    /// 上一次算变换时**正文的 frame** —— 它变了（转屏 / 改字号 / 换了行）才重算。
    ///
    /// 🔴 盯的是正文而不是容器的宽度：纵向补偿按**正文中心**算，正文位置一变就得跟着变。
    private var appliedTransformBounds: CGRect = .null

    /// 上一次算变换时**容器的尺寸** —— 纵向补偿用的是容器中心，容器尺寸一变它也得重算。
    ///
    /// ⚠️ 光盯正文 frame 不够：正文在 `stack` 顶部，附属字多寡变了容器会变高、正文 frame
    /// 却一动不动，那一项补偿就漏算了。
    private var appliedContainerSize: CGSize = .zero

    /// **`scaledContainer.transform` 的唯一写者。**
    ///
    /// 两个输入各管各的、互不覆盖：`normalScale` 是常驻状态（这一行是不是当前行），
    /// `cascadeOffset` 是换行那一趟的临时位移。两个状态量在一个地方合成一次写进去 ——
    /// 不是"两个写者靠调用顺序让路"。
    ///
    /// ⚠️ 缩放**只改画出来的样子**，占位/行高一个字节都不动 —— 这正是它比"换字号"好的
    /// 地方（换字号会让整篇重新排版，而歌词列表每帧都在滚）。见 `AppFont.lyricsLine`。
    ///
    /// 🔴 **纵向锚点是正文的中心，横向跟着对齐走。**
    ///
    /// primuse 的 `scaleAnchor` 纵向恒为 `0.5`（`FullscreenPlayerEffectSettings`），
    /// 横向才跟 leading / center / trailing 走 —— 方向对，但**它的行里只有正文**，
    /// 「整体居中」和「正文居中」是同一件事。我们这行**正文 ＋ 附属字**两段，
    /// 整体中心落在两者之间，照搬 `0.5` 锚的就是错的那个点。
    ///
    /// 锚点试了四次（2026-11-15）：整体中心 → 顶部 → 回整体中心 → 正文中心。
    /// 前三次都在围着 `contentView` 转（整体中心让正文下移、顶部让它向下长）；
    /// 第四次锚点算对了**仍然不对** —— 那时还没发现 `contentView` 的 `bounds`
    /// 每布一次局就被撑大一次（见 `scaledContainer` 那段），
    /// 锚点算得再准，也被一个每帧都在变的尺寸推翻。
    ///
    /// MeloX 的 `.top` 更不能照搬：它幅度只有 2%（`deselectedScale: 0.98`），
    /// 那种量级任何锚点都看不出来；我们 10%，锚错一点就露。
    private func applyTransform() {
        let scale = normalScale
        let width = max(scaledContainer.bounds.width, 0)
        appliedTransformBounds = textLabel.frame
        appliedContainerSize = scaledContainer.bounds.size
        // 横向：以中心缩放后左边缘会往中间收 `宽度 × (1 − scale) / 2` —— 按对齐把它推回去。
        let shift = width * (1 - scale) / 2
        let dx: CGFloat
        switch scaleAlignment {
        case .left: dx = -shift
        case .center: dx = 0
        case .right: dx = shift
        }
        // 🔴 纵向锚点是**正文自己的中心**，不是整个容器的中心。
        //
        // 有附属字（译文 / 注音）时，正文在上半部、附属字在下半部 ⇒ **正文中心在
        // 容器中心上方**。以整体中心缩放，正文就会**往下移**。
        //
        // 以正文中心为锚点 ⇒ 正文上下对称地变、重心不动；没有附属字时
        // `textLabel.frame.midY ≈ 容器 midY`，这一项自然归零。
        //
        // ⚠️ `textLabel.frame` 是相对 `stack` 的；`stack` 顶在 `scaledContainer` 的 0 上
        // （`buildSubviews` 里 `make.top.equalToSuperview()`），两个坐标系纵向同源，能直接减。
        // 将来若给 `stack` 加上边距，这里要改成 `stack.convert(textLabel.frame, to: scaledContainer)`。
        let textMidY = textLabel.frame.midY
        let dy = cascadeOffset + (textMidY - scaledContainer.bounds.midY) * (1 - scale)
        scaledContainer.transform = CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy
        )
    }

    /// 摆一行。`isCurrent` 决定**顶字的透明度**（当前行 1 / 普通行 0）和**缩放**（1.0 / 0.9）；
    /// 字体本身不分档；`alignment` 是用户选的对齐（正文与附属字**同一档**）。
    ///
    /// 🔴 **两层的颜色各管一档、恒定不变**：底字永远是「普通行那一档」（`overlayTint`），
    /// 顶字永远是「当前行那一档」（纯白）。**当前行程度就是顶字的 `alpha`（0…1）** ——
    /// 于是「从当前行到普通行」不是换颜色，而是**顶字淡出**。这么做的两个好处：
    ///
    /// 1. **颜色不需要动画**：颜色写在属性串里（不可动画），但它的值不再变化；
    ///    变的只有一个 `alpha`，那是 Core Animation 最擅长的事。
    /// 2. **有逐字 / 没逐字合成一条路**：没逐字时顶字不挂 mask（整行显示），
    ///    有逐字时挂 mask（按扫光揭开）—— 两者都只是"顶字露多少"，不再分两套颜色逻辑。
    func show(
        line: LyricsLine, isCurrent: Bool, baseFontSize: CGFloat, alignment: LyricsAlignment
    ) {
        let textAlignment = Self.textAlignment(for: alignment)
        self.line = line
        self.baseFontSize = baseFontSize
        self.appliedTextAlignment = textAlignment
        self.scaleAlignment = alignment

        let font = AppFont.lyricsLine(baseSize: baseFontSize)
        textLabel.attributedText = Self.attributed(
            line.text, font: font, color: AppColor.overlayTint, alignment: textAlignment
        )
        highlightLabel.attributedText = Self.attributed(
            line.text, font: font, color: AppColor.nowPlayingSolid, alignment: textAlignment
        )

        applyKaraokeLayer(isCurrent: isCurrent)
        applyCompanions(
            line.companionTexts, baseFontSize: baseFontSize, alignment: textAlignment
        )
        // 格子刚出生（或滚动到）⇒ 直接给终态。换行那两行**不走这儿**：
        // 它们由交错滚动的动画从旧状态带过去（`setCascadeOffset` → `endTransition`）。
        endTransition(isCurrent: isCurrent)
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

        // ⚠️ 不碰 `isHidden` / `alpha` —— 顶字露多少归 `endTransition` 管（那是过渡的连续量）。
        if highlightLabel.layer.mask !== maskHost { highlightLabel.layer.mask = maskHost }
        // 🔴 **框必须在这儿给一次**：`layoutSubviews` 跑在 cell 那一层、比里面的字**早**，
        // 它拿到的 `highlightLabel.bounds` 是上一次布局的；只有这里（每帧画的时候）
        // 拿到的一定是当前尺寸。少了这一句 ⇒ 第一次挂遮罩时框是 0 ⇒ 顶字整行被遮掉；
        // 尺寸变了以后 ⇒ 图是新尺寸、框是旧的 ⇒ 高亮块被拉伸错位。
        // `layoutSubviews` 里那一份不是重复：它管**不画帧的时候**（暂停 / 冻住）转屏、改字号。
        maskHost.frame = highlightLabel.bounds
        maskHost.contentsScale = traitCollection.displayScale
        maskHost.contents = image
    }

    /// 把逐字那一层整个收掉（非当前行 / 换行表 / 换字号 / 复用前）。
    ///
    /// ⚠️ 只摘 mask 和缓存，**不动 `alpha`**：mask 摘掉之后顶字是"整行显示"，
    /// 那正是"当前行但没有逐字"要的样子；普通行看不见它是因为 `alpha` 是 0。
    func clearKaraoke() {
        karaokeSegments = nil
        karaokeText = nil
        karaokeFont = nil
        karaokeParagraph = nil
        karaokeRenderer.invalidate()
        highlightLabel.layer.mask = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskHost.contents = nil
        CATransaction.commit()
    }

    /// 这一行摆出来要多高 —— 跟下面的约束是同一套算法（见类型顶上那段）。
    ///
    /// 🔴 **跟"是不是当前行"无关**：所有行按同一个字号算高。当前行/普通行的大小差别
    /// 走 `transform`，不动占位 —— 所以行高恒定，换行时列表不用重排。
    ///
    /// `width` 是列表给的可用宽（已经扣掉左右边距）。
    static func height(
        for line: LyricsLine, width: CGFloat, baseFontSize: CGFloat
    ) -> CGFloat {
        guard width > 0 else { return 0 }

        var total = textHeight(
            line.text,
            font: AppFont.lyricsLine(baseSize: baseFontSize),
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

        // 🔴 **内容全部挂在 `scaledContainer` 下，不直接挂 `contentView`** ——
        // 缩放与位移写的是它（见 `applyTransform` 上面那段）。`contentView` 保持原样，
        // 系统每帧重设它的 `frame` 也伤不到我们。
        contentView.addSubview(scaledContainer)
        scaledContainer.addSubview(stack)

        // 顶字：**四边贴住正文**（约束可以跨层级 —— 它俩最终都落在 `scaledContainer` 里）。
        //
        // 🔴 用"贴 `textLabel`"而不是"另起一层容器"：`textLabel` 继续当 `stack` 的排列子视图，
        // `height(for:)` 那条**尺寸链一个字都不用改**（它跟这儿的约束必须是同一套算法，见类型顶上那段）。
        // ⚠️ 加在 `stack` **之后** ⇒ 它压在正文上面。
        highlightLabel.numberOfLines = 0
        highlightLabel.lineBreakMode = .byWordWrapping
        // ⚠️ **用 `alpha` 不用 `isHidden`**：当前行程度就是这一层的透明度（0…1），
        // 过渡就是它渐变 —— `isHidden` 是布尔量，变不了。
        highlightLabel.alpha = 0
        scaledContainer.addSubview(highlightLabel)

        // mask 只挂一个层；图由 `renderKaraoke` 写进 `contents`。
        maskHost.contentsGravity = .resize

        // 🔴 **`scaledContainer` 用普通约束摆（四边贴住 `contentView`），不要改成手动 `bounds`。**
        //
        // 试过"零约束 ＋ `translatesAutoresizingMaskIntoConstraints = false` ＋ 在
        // `layoutSubviews` 里手动给 `bounds`/`center`"，**结果是整行字挤到屏幕左侧**：
        // 没有约束的视图在 autolayout 引擎里**没有位置**，引擎按 (0, 0, 0, 0) 处理，
        // 手动设的值下一拍就被覆盖掉。
        //
        // 而 autolayout 解约束走的是 `bounds` ＋ `center`（不是 `setFrame:`），
        // **不会**反算尺寸 —— `contentView` 那个病是 `UICollectionViewCell` 自己用
        // `setFrame:` 设它的 `frame` 造成的，跟约束无关。两者不是一回事。
        scaledContainer.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

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

    /// 布局这一拍要做两件事：正文位置 / 容器尺寸变了就重算缩放；遮罩的框跟着文字尺寸补一次。
    ///
    /// ⚠️ 这里的 `highlightLabel.bounds` 是**上一次**布局的（cell 比里面的字早），
    /// 所以遮罩框**不能只靠这一处** —— 每帧画的那条路也要设一次，见 `renderKaraoke(at:)`。
    override func layoutSubviews() {
        super.layoutSubviews()
        // ⚠️ `scaledContainer` 的位置和尺寸**由约束管**（见 `buildSubviews`）——
        // 别在这儿手动给 `bounds`：零约束的视图在 autolayout 里没有位置，
        // 手动设的值会被引擎按 (0,0,0,0) 覆盖，字全挤到左边。

        // 补偿按**正文的位置**和**容器的尺寸**算 —— 两者任一变了（转屏 / 改字号 / 换了行 /
        // 附属字多寡变了）就得重算一次。`show(...)` 那一刻还没布局，所以这里必须补上。
        if textLabel.frame != appliedTransformBounds
            || scaledContainer.bounds.size != appliedContainerSize {
            applyTransform()
        }
        // 🔴 遮罩的框在这儿**再补一次**：这一句管的是「**不画帧的时候**尺寸变了」——
        // 暂停 / 冻住时 `renderKaraoke` 不再被调，转屏或改字号就只能靠布局这一拍跟上。
        // ⚠️ 这里读到的 `highlightLabel.bounds` 是**上一次布局**的（cell 的 `layoutSubviews`
        // 比里面的字早），所以它**不能替代** `renderKaraoke` 里那一句，两句都要。
        guard highlightLabel.layer.mask != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskHost.frame = highlightLabel.bounds
        maskHost.contentsScale = traitCollection.displayScale
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
