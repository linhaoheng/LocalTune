import UIKit

/// 「编辑歌词」页里的**逐字块条** —— 一行歌词的行内逐字标记，铺成一条能点的块。
///
/// 两处用**同一份**：逐行页的每一行（这一行有逐字才画）、打轴页的「逐字打轴」。
///
/// ## 🔴 三处口径
///
/// 1. **块是"现解析出来的一张脸"，不是模型**：
///    `apply(items:activeIndex:)` 吃的是 `LyricsSyllableTimingPolicy` 当场算出来的数组，
///    本视图**不留任何缓存** —— 所以不存在"两份表示谁保证一致"的问题。
/// 2. **换行是自算的**：块宽随字而变，`UIStackView` 铺不出这种。
///    高度 = `f(字块, 排版宽度)`，经 `preferredLayoutWidth` → `intrinsicContentSize` 进 Auto Layout
///    （和 `UILabel.preferredMaxLayoutWidth` 同一条路）—— **测量那一趟就要是真高度**，
///    不许先报 0 再事后 `beginUpdates` 补救。
/// 3. **点某一块 = 把下标递出去** —— 跳到第几秒由页面（`LyricsEditorViewModel`）定，
///    这一层不认识播放器。
final class LyricsEditorSyllableStripView: UIView {

    /// 点了第几块 —— 页面负责"跳到这个字的起点"（**不自动播放**）。
    var onTapChip: ((Int) -> Void)?

    /// 排版宽度（字块按这个宽换行）。表格测量前由 cell 写成正文列的宽。
    ///
    /// 🔴 没有它、又只靠 `bounds.width`：`automaticDimension` 问高度时宽度往往还是 0，
    /// 固有高度就会报 0 —— 这就是「有逐字进页整句和字块叠在一起」的根因。
    var preferredLayoutWidth: CGFloat = 0 {
        didSet {
            guard abs(preferredLayoutWidth - oldValue) > 0.5 else { return }
            invalidateIntrinsicContentSize()
        }
    }

    private var items: [LyricsEditorSyllable] = []
    private var activeIndex: Int?
    private var buttons: [UIButton] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // 竖直方向以固有高度为准，别被栈压扁。
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    /// 高度唯一出处：有字块 + 有排版宽 ⇒ 按换行算；否则 0。
    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: Self.contentHeight(items: items, width: layoutWidth)
        )
    }

    // MARK: - 摆

    /// 画成给定的块。**内容跟上次一模一样就不动**（复用池里多数是同一行）。
    ///
    /// - Parameter activeIndex: 点亮哪一块 —— 逐行页是**用户点选的那个字**，打轴页是
    ///   **正在打的那个字**。🔴 两处含义不同，都由调用方决定（本视图既不认识播放器、
    ///   也不认识"点选"这件事）。逐行页那份**不跟播放头**：跟播放的是行，不是字。
    func apply(items: [LyricsEditorSyllable], activeIndex: Int?) {
        guard items != self.items || activeIndex != self.activeIndex else { return }
        self.items = items
        self.activeIndex = activeIndex
        rebuildChips()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let available = bounds.width
        guard available > 0 else { return }
        // 真到屏上以后，以实际宽度为准（旋转等）；与测量前 cell 写进来的值对齐。
        if abs(preferredLayoutWidth - available) > 0.5 {
            preferredLayoutWidth = available
        }
        let frames = Self.frames(
            widths: items.map(Self.chipWidth),
            availableWidth: available
        )
        for (index, button) in buttons.enumerated() where frames.indices.contains(index) {
            button.frame = frames[index]
        }
    }

    // MARK: - 私有 · 建

    private func rebuildChips() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = items.enumerated().map { index, item in
            let active = index == activeIndex
            let button = UIButton(type: .system)
            button.tag = index
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.textAlignment = .center
            button.layer.cornerRadius = AppMetrics.lyricsEditorSyllableChipCornerRadius
            button.layer.cornerCurve = .continuous
            // 🔴 选中 = **淡染底 ＋ 1pt 描边 ＋ 字变强调色**，不是实心块 ＋ 白字。
            // 描边那一笔是必需的：底色跟「当前句」行高亮同一档，没它分不出选中的是哪一块。
            button.backgroundColor = active
                ? AppColor.lyricsEditorSyllableSelectedFill
                : AppColor.lyricsEditorSyllableFill
            button.layer.borderWidth = active ? AppMetrics.lyricsEditorSyllableChipBorderWidth : 0
            button.layer.borderColor = AppColor.lyricsEditorSyllableSelectedBorder.cgColor
            button.setAttributedTitle(Self.title(for: item, active: active), for: .normal)
            button.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
            addSubview(button)
            return button
        }
    }

    /// 块上两行：词 / 起点时间。
    ///
    /// 🔴 **只有"词"跟着选中态变**（常态主文字 → 选中强调色）；**时间那一行两态都是次级文字** ——
    /// 它是脚注，选中的那一块里也不该跟词一样响。
    private static func title(for item: LyricsEditorSyllable, active: Bool) -> NSAttributedString {
        // 选中词色跟工作台一样走 `AccentColor`（见 `AppColor.lyricsEditorAccent`），
        // 不用页面通用的 `AppColor.accent`（Radix blue9）—— 两颗蓝不是同一个。
        let textColor = active ? AppColor.lyricsEditorAccent : AppColor.title
        let timeColor = AppColor.subtitle

        let title = NSMutableAttributedString(
            string: visibleText(item.text) + "\n",
            attributes: [.font: AppFont.lyricsEditorSyllableChip, .foregroundColor: textColor]
        )
        title.append(
            NSAttributedString(
                string: LyricsEditorPolicy.format(item.start),
                attributes: [.font: AppFont.lyricsEditorSyllableChipTime, .foregroundColor: timeColor]
            )
        )
        return title
    }

    /// 空格 / 换行在块里看不出来，画成可见符号；整块是空的画 `--`（占位）。
    private static func visibleText(_ text: String) -> String {
        let visible = text
            .replacingOccurrences(of: " ", with: "␠")
            .replacingOccurrences(of: "\n", with: "↵")
        return visible.isEmpty ? "--" : visible
    }

    // MARK: - 私有 · 量

    private var layoutWidth: CGFloat {
        if preferredLayoutWidth > 0 { return preferredLayoutWidth }
        return bounds.width
    }

    /// 给定字块 + 排版宽 ⇒ 条的总高。宽度未知或没字 ⇒ 0。
    private static func contentHeight(items: [LyricsEditorSyllable], width: CGFloat) -> CGFloat {
        guard !items.isEmpty, width > 0 else { return 0 }
        return frames(
            widths: items.map(chipWidth),
            availableWidth: width
        ).last.map(\.maxY) ?? 0
    }

    /// 一块要占多宽 —— **取「词」和「时间」里宽的那行**，再加两边留白；
    /// **最窄 44、最宽 166**（工作台 `minWidth` / `maxWidth`）。
    private static func chipWidth(_ item: LyricsEditorSyllable) -> CGFloat {
        let textWidth = (visibleText(item.text) as NSString)
            .size(withAttributes: [.font: AppFont.lyricsEditorSyllableChip]).width
        let timeWidth = (LyricsEditorPolicy.format(item.start) as NSString)
            .size(withAttributes: [.font: AppFont.lyricsEditorSyllableChipTime]).width
        let content = ceil(max(textWidth, timeWidth)) + AppMetrics.lyricsEditorSyllableChipPadding * 2
        return min(
            max(content, AppMetrics.lyricsEditorSyllableChipMinWidth),
            AppMetrics.lyricsEditorSyllableChipMaxWidth
        )
    }

    /// 从左往右铺、铺不下就换行。
    ///
    /// ⚠️ 单块比整行还宽时**夹到整行宽**（不然它会顶出视图外，右边永远看不到）。
    private static func frames(widths: [CGFloat], availableWidth: CGFloat) -> [CGRect] {
        let spacing = AppMetrics.lyricsEditorSyllableChipSpacing
        let height = AppMetrics.lyricsEditorSyllableChipHeight
        var result: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0

        for width in widths {
            let clamped = min(width, availableWidth)
            if x > 0, x + clamped > availableWidth {
                x = 0
                y += height + spacing
            }
            result.append(CGRect(x: x, y: y, width: clamped, height: height))
            x += clamped + spacing
        }
        return result
    }

    // MARK: - 事件

    @objc private func chipTapped(_ sender: UIButton) {
        onTapChip?(sender.tag)
    }
}
