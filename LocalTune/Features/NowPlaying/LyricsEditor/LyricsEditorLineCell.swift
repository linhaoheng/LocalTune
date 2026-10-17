import SnapKit
import UIKit

/// 「编辑歌词」页「逐行」模式里的一行 —— **时间键 ＋ 可编辑正文 ＋ 逐字条 ＋ 当前字细条 ＋ 问题角标**。
///
/// 📍 **整行版式照工作台写**（`LocalTune1` 的 `LyricsStudioLineRowView`）：
/// 一行就是一块**圆角 6 的底板**（当前句淡染强调色 10%，其余透明），内容在板内左右 10 / 上下 6；
/// 时间键是一颗 11pt 的小圆角徽章；正文 13pt；逐字条跟正文同一个左边界。
///
/// ## 🔴 六处口径
///
/// 1. **时间键两态**（对齐工作台 `timestampChip`）：**已打轴** = 画时刻、点了跳过去听；
///    **未打轴** = 画「打点」、点了用当前播放进度给这一行打上时间。
/// 2. 🔴 **正文框里只有歌词本身**：行内逐字标记由 `LyricsSyllableTimingPolicy.plainText(inLine:)`
///    去掉后再显示 —— 时间只走下面那条逐字块。
///    ⇒ **改一次字 = 这一行的逐字标记作废**（正文是唯一真相，标记就是正文的一部分；
///    跟工作台 `replaceText` 清掉 `syllables` 是同一个后果）。
/// 3. **逐字条画在每一行**（这一行有逐字才有），**当前字细条只画在"用户点中的那一行"** ——
///    每行都画细条的话，一张两百行的表会变成一堵墙。
/// 4. 🔴 **逐字高亮只认用户点选**（`selectedSyllableIndex`），**不跟播放头** ——
///    跟播放的是**行**（`highlighted`），不是字。primuse 文本模式同样只看 `selectedTextSyllable`
///    （`LyricsEditorView.swift:1869`），播放头那份 `timingSyllableIndex` 只在打轴页。
/// 5. **模型仍然只有 `time + text`**：逐字块是 `LyricsSyllableTimingPolicy` **当场从正文解析**
///    出来的一张脸，本格**不缓存**。
/// 6. **「值相同就不写」**（`apply` 里那句 `guard`）：往文本框里写它刚发出来的同一份字，
///    会把光标顶到末尾、还会经 `textViewDidChange` 形成回环 —— 本来就可以不写。
final class LyricsEditorLineCell: UITableViewCell, UITextViewDelegate {

    static let reuseID = "LyricsEditorLineCell"

    /// 点了时间键 —— 有轴 / 无轴由页面按行模型分支（跳转 或 打点），本格不猜。
    var onTimeButton: (() -> Void)?

    /// 点了逐字条上第几块 —— 页面负责"选中这个字，并跳到它的起点"（**不自动播放**）。
    var onTapSyllable: ((Int) -> Void)?

    /// 点了细条上的 `±` —— 递出这一下要挪多少秒。
    var onNudgeSyllable: ((TimeInterval) -> Void)?

    /// 正文被改了 —— 把**这一刻的正文**递出去（**每次按键都发**）。
    ///
    /// 🔴 参数是 `String` 而不是让页面再回读 cell：闭包若强抓 cell，会跟 cell 持有的
    /// `onText` 互相引用成环；复用池里的格子就永远放不掉。
    var onText: ((String) -> Void)?

    /// 这一行的正文框。页面在收起键盘 / 滚动时要用它（同一行只能有一个第一响应者）。
    private(set) var textView: UITextView!

    /// 一行的**圆角底板** —— 工作台那行的高亮就是一块圆角 6 的板子，不是整格平铺。
    /// 🔴 挂在 `backgroundView`（系统就把它垫在 `contentView` 底下），随 `highlighted` 换色。
    private let rowBackground = UIView()

    // 🔴 `.custom` 而不是 `.system`：系统键一改 `title` / `attributedTitle` 会自带淡入交叉淡出；
    // 可见行每次快照都 `apply`，不改时刻也会被拆掉重建一遍 —— 进页、改别人时间都会闪（副本 82 不会）。
    private let timeButton = UIButton(type: .custom)
    private let issueLabel = UILabel()
    /// 逐字块条 ＋ 当前字细条 —— 两件都在 `syllableStack` 里，靠 `isHidden` 收放。
    private let syllableStack = UIStackView()
    private let stripView = LyricsEditorSyllableStripView()
    private let detailView = LyricsEditorSyllableDetailView()
    /// 逐字条到正文那道间距 —— **它是可变的**：这一行没有逐字时整条收起来，间距跟着归零。
    private var syllableTop: Constraint?

    /// 时间键的宽度 —— **随字走**（`apply` 里量时刻字符串写进来，内衬算在里头）。
    private var timeButtonWidth: Constraint?

    /// 上一次已经画到键上的态。跟正文同一道闸：**值相同就不写**，避免无意义的拆建。
    private enum AppliedTime: Equatable {
        case unstamped
        case stamped(centiseconds: Int)

        init(_ time: TimeInterval?) {
            if let time {
                self = .stamped(centiseconds: LyricsEditorPolicy.centiseconds(time))
            } else {
                self = .unstamped
            }
        }
    }

    private var appliedTime: AppliedTime?

    // MARK: - 建立

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        setUpSubviews()
        setUpConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // 复用前摘掉闭包 —— 上一行的行号不该跟着这格走出去。
        onTimeButton = nil
        onTapSyllable = nil
        onNudgeSyllable = nil
        onText = nil
        appliedTime = nil
    }

    private func setUpSubviews() {
        // 🔴 圆角走 **continuous**（工作台 `RoundedRectangle(..., style: .continuous)`）——
        // 默认 circular 在 6pt 这种小半径上偏鼓，跟整理文本页那块板对不上。
        rowBackground.layer.cornerRadius = AppMetrics.lyricsEditorRowCornerRadius
        rowBackground.layer.cornerCurve = .continuous
        rowBackground.clipsToBounds = true
        backgroundView = rowBackground

        // 🔴 小圆角徽章：已打轴 / 未打轴两态都在 `applyTimeButton` 里摆齐
        // （工作台 `timestampChip`）。不用 `Configuration` —— 和工具条同一处「框暗」。
        timeButton.layer.cornerRadius = AppMetrics.lyricsEditorRowTimeButtonCornerRadius
        timeButton.layer.cornerCurve = .continuous
        timeButton.tintColor = AppColor.lyricsEditorAccent
        timeButton.addTarget(self, action: #selector(timeTapped), for: .touchUpInside)

        textView = UITextView()
        textView.delegate = self
        textView.font = AppFont.lyricsEditorRowText
        textView.textColor = AppColor.title
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(
            top: AppMetrics.lyricsEditorRowTextVerticalInset,
            left: 0,
            bottom: AppMetrics.lyricsEditorRowTextVerticalInset,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        // 关掉输入法的自作聪明：歌词里常有连字符、真引号，它们会被悄悄替换掉。
        textView.autocorrectionType = .no
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no

        issueLabel.font = AppFont.lyricsEditorRowIssue
        issueLabel.textColor = AppColor.accent
        issueLabel.numberOfLines = 2

        // 🔴 逐字条 / 细条收在一个竖栈里：**藏起来的 arranged 子视图不占位** ——
        // 所以"这一行没有逐字"时下面那块高度自然归零，问题角标自己贴回正文下沿。
        syllableStack.axis = .vertical
        syllableStack.alignment = .fill
        syllableStack.spacing = 0
        syllableStack.addArrangedSubview(stripView)
        syllableStack.addArrangedSubview(detailView)
        syllableStack.setCustomSpacing(AppMetrics.lyricsEditorSyllableDetailTop, after: stripView)

        stripView.onTapChip = { [weak self] index in self?.onTapSyllable?(index) }
        detailView.onNudge = { [weak self] delta in self?.onNudgeSyllable?(delta) }

        contentView.addSubview(timeButton)
        contentView.addSubview(textView)
        contentView.addSubview(syllableStack)
        contentView.addSubview(issueLabel)
    }

    /// 测量前把正文列宽交给逐字条（`preferredLayoutWidth`），固有高度在这一趟就是真值。
    ///
    /// 逐字条高度 = f(字块, 排版宽)；宽未知时固有高度只能是 0。这里先让横向约束落下、
    /// 读出正文列宽再问总高 —— 和 `UILabel` 先设 `preferredMaxLayoutWidth` 再量多行，是同一条路。
    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let width = targetSize.width
        if width > 0, abs(contentView.bounds.width - width) > 0.5 {
            contentView.bounds.size.width = width
        }
        contentView.layoutIfNeeded()
        stripView.preferredLayoutWidth = textView.bounds.width
        return super.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority
        )
    }

    private func setUpConstraints() {
        timeButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(AppMetrics.lyricsEditorRowInsetHorizontal)
            make.top.equalToSuperview().offset(AppMetrics.lyricsEditorRowTimeButtonTop)
            make.height.equalTo(AppMetrics.lyricsEditorRowTimeButtonHeight)
            timeButtonWidth = make.width.equalTo(AppMetrics.lyricsEditorRowTimeButtonMinWidth).constraint
        }
        textView.snp.makeConstraints { make in
            make.leading.equalTo(timeButton.snp.trailing).offset(AppMetrics.lyricsEditorRowTextGap)
            make.trailing.equalToSuperview().offset(-AppMetrics.lyricsEditorRowInsetHorizontal)
            make.top.equalToSuperview().offset(AppMetrics.lyricsEditorRowInsetVertical)
        }
        // 🔴 逐字条**跟正文同一个左边界**（缩过时间键那一列）—— 不贴着表格左沿。
        // 与正文之间再留 `lyricsEditorSyllableStripTop`：正文框自己下沿还有一层内缩，
        // 两段加起来才是眼睛看到的间距（贴太近句子和字块会糊成一片）。
        syllableStack.snp.makeConstraints { make in
            make.leading.trailing.equalTo(textView)
            syllableTop = make.top.equalTo(textView.snp.bottom)
                .offset(AppMetrics.lyricsEditorSyllableStripTop).constraint
        }
        issueLabel.snp.makeConstraints { make in
            make.leading.trailing.equalTo(textView)
            make.top.equalTo(syllableStack.snp.bottom)
            make.bottom.equalToSuperview().offset(-AppMetrics.lyricsEditorRowInsetVertical)
        }
    }

    // MARK: - 摆

    /// 把这一行画成给定的样子。
    ///
    /// - Parameters:
    ///   - time: 行时间（`nil` ＝ 还没打轴，画「打点」键）。
    ///   - text: 正文（**模型那一份，行内可能带逐字标记** —— 显示前由这里去掉）。
    ///   - issues: 这一行的问题（**空数组 ＝ 没有**，角标整颗藏起来）。
    ///   - highlighted: 是不是「当前这一句」（光标那一行；跟随播放时它就是正在唱的那句）。
    ///   - syllables: 这一行的逐字块 —— **由页面现解析递进来**，本格不自己算。
    ///   - selectedSyllableIndex: 用户点中的那个字（`nil` ＝ 这一行没点过）——
    ///     🔴 **不跟播放头**（口径第 4 条）。
    func apply(
        time: TimeInterval?,
        text: String,
        issues: [LyricIssueKind],
        highlighted: Bool,
        syllables: [LyricsEditorSyllable],
        selectedSyllableIndex: Int?
    ) {
        applyTimeButton(time: time)

        // 🔴 正文框里只放**歌词本身** —— 行内 `<mm:ss.xx>` 由逐字条承担（口径第 2 条）。
        let display = LyricsSyllableTimingPolicy.plainText(inLine: text)
        // **值相同就不写**（口径第 6 条）—— 复用时正文框里往往就是同一份字（用户刚打完没松手
        // 就被重排了）。每次都写会把光标顶到末尾、还会触发一次 `textViewDidChange`（→ 页面又重排 → 死循环）。
        if textView.text != display { textView.text = display }

        let labels = issues.map(\.label)
        issueLabel.text = labels.isEmpty ? nil : labels.joined(separator: " · ")
        issueLabel.isHidden = labels.isEmpty

        applySyllables(syllables, selectedIndex: selectedSyllableIndex, lineTime: time)
        // 🔴 「当前句」的淡染画在**行自己的圆角底板**上（工作台那行就是这么画的），
        // 不再整格平铺 —— 平铺的色块直怼到表格卡片两沿，跟工作台"一块独立的板子"两副面孔。
        rowBackground.backgroundColor = highlighted ? AppColor.lyricsEditorCurrentLine : .clear
    }

    /// 逐字这两块：**条画在每一行，细条只画在用户点中的那一行**。
    ///
    /// 🔴 点亮哪一块**只由用户点选决定**，播放头不参与 —— 所以 `highlighted`（是不是当前行）
    /// 在这里**用不上**，参数里干脆不要，免得又被拿来"顺手点亮正在唱的那个字"。
    private func applySyllables(
        _ syllables: [LyricsEditorSyllable],
        selectedIndex: Int?,
        lineTime: TimeInterval?
    ) {
        // 🔴 **有逐字才留那道间距**：条整体收起来时把间距一起归零。常数留着的话，
        // 每个"没有逐字"的行都会平白多出那几个点（§N.8 第 1 条要的是**正文和逐字之间**的空，
        // 不是"全表长高"）。
        syllableTop?.update(offset: syllables.isEmpty ? 0 : AppMetrics.lyricsEditorSyllableStripTop)
        stripView.isHidden = syllables.isEmpty
        // 点选的字在正文改过之后可能已经不存在了（标记没了）—— 越界就当没点过。
        let selected = selectedIndex.flatMap { syllables.indices.contains($0) ? $0 : nil }
        stripView.apply(items: syllables, activeIndex: selected)

        guard let selected else {
            detailView.isHidden = true
            return
        }
        let room = LyricsSyllableTimingPolicy.nudgeRoom(
            in: syllables, at: selected, lineTime: lineTime
        )
        detailView.isHidden = false
        detailView.apply(
            LyricsEditorSyllableDetailView.Content(
                position: selected + 1,
                count: syllables.count,
                start: syllables[selected].start,
                canDecrease: room.canDecrease,
                canIncrease: room.canIncrease
            )
        )
    }

    /// 收掉这一行的键盘（**没有键盘开着就什么都不做**）。
    ///
    /// 页面点时间键 / 逐字块之前会叫它一遍：那一格正拿着键盘时，重画它会把输入会话打断
    /// （用户正改词、顺手点一下，键盘一收等于半句话没了）。
    func endEditingIfNeeded() {
        guard textView.isFirstResponder else { return }
        textView.resignFirstResponder()
    }

    // MARK: - 时间键两态

    /// 有时间 ⇒ 时刻徽章；没时间 ⇒「打点」徽章（工作台 `timestampChip` 同构）。
    ///
    /// 🔴 两支**都**要自己写 `titleLabel.font`（见下面那条）—— 键是复用的，字体不写就是残留值。
    private func applyTimeButton(time: TimeInterval?) {
        // 值相同就不写 —— 快照一推，可见行整排 `apply`；时刻没变却拆 title/attributedTitle，
        // 就是「改一个、别的闪一下」的根。
        let next = AppliedTime(time)
        if appliedTime == next { return }
        appliedTime = next

        let padding = AppMetrics.lyricsEditorRowTimeButtonPadding
        let minWidth = AppMetrics.lyricsEditorRowTimeButtonMinWidth

        if let time {
            let title = LyricsEditorPolicy.format(time)
            timeButton.setImage(nil, for: .normal)
            timeButton.setAttributedTitle(nil, for: .normal)
            timeButton.setTitle(title, for: .normal)
            timeButton.titleLabel?.font = AppFont.lyricsEditorRowTime
            timeButton.setTitleColor(AppColor.lyricsEditorAccent, for: .normal)
            timeButton.backgroundColor = AppColor.lyricsEditorRowTimeFill
            timeButton.accessibilityLabel = "跳到 \(title)"
            let titleWidth = (title as NSString)
                .size(withAttributes: [.font: AppFont.lyricsEditorRowTime]).width
            timeButtonWidth?.update(
                offset: max(minWidth, ceil(titleWidth) + padding * 2)
            )
            return
        }

        // 未打轴 = 一颗**只有「打点」两个字**的徽章（浅灰底、强调色字），
        // 跟上面那支一样走 `setTitle` —— 两态同一套摆法，面上是什么字、什么字都由本分支定。
        let title = LyricsEditorPolicy.unstampedLineTimeButtonTitle
        timeButton.setImage(nil, for: .normal)
        timeButton.setAttributedTitle(nil, for: .normal)
        timeButton.setTitle(title, for: .normal)
        // 🔴 **这一行不能省**：两态共用同一颗会被复用池到处搬的键，`titleLabel.font` 是**残留状态**——
        // 谁不写，谁就继承上一行的字体（搬到"刚显示过时刻"的格子上就是 11 等宽，搬进新格子则是
        // UIButton 的默认字）。两个分支各写各的，字体来源才是唯一且可预期的。
        timeButton.titleLabel?.font = AppFont.lyricsEditorRowStamp
        timeButton.setTitleColor(AppColor.lyricsEditorAccent, for: .normal)
        timeButton.backgroundColor = AppColor.lyricsEditorRowStampFill
        timeButton.accessibilityLabel = "给这一行打点"
        let titleWidth = (title as NSString)
            .size(withAttributes: [.font: AppFont.lyricsEditorRowStamp]).width
        timeButtonWidth?.update(
            offset: max(minWidth, ceil(titleWidth) + padding * 2)
        )
    }

    // MARK: - 事件

    @objc private func timeTapped() { onTimeButton?() }

    func textViewDidChange(_ textView: UITextView) {
        onText?(textView.text)
    }
}
