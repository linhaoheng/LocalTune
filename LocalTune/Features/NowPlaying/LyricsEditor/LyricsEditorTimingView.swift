import SnapKit
import UIKit

/// 「编辑歌词」页的「打轴」主区 —— **打轴时最该看的那一屏**。
///
/// 📍 版式，七块自上而下：
/// 上一句 · 行号 · **当前行已打的轴** · **当前句（22 半粗）** · 下一句 · 未打轴汇总 · 主按钮「打时间点并下一行」（48 高）。
///
/// 🔴 两处要对齐：
/// 1. **不存草稿、不存行号** —— 只接收 `Snapshot` 画出来。
/// 2. **中间时间格是「当前行已打的轴」**，不是播放头；
///    未打轴画 `--:--`（与行 cell 同一占位，保高度；空串会把 stack 挤扁）。
///    播放进度只在歌曲条。打点读的是页面当时的 `PlayManager.currentPosition`，
///    这一层**不碰播放器**。
///
/// ⚠️ **布局**：VC 主区仍吃满剩余视口。本视图内部用一块 **360 高卡片**
/// （`timingView.height = 360`），竖栈四边 inset 8、spacing 14。
/// 装不满的余量给「上一句」（它是唯一纵向可拉的块）；主区比 360 高的部分留在卡片下面。
final class LyricsEditorTimingView: UIView {

    private let previousLyricLabel = UILabel()
    private let currentLineNumberLabel = UILabel()
    private let currentTimeLabel = UILabel()
    private let currentLyricLabel = UILabel()
    /// 「逐字打轴」那一页**多的两条**：逐字块条 ＋ 当前字细条。
    private let syllableStack = UIStackView()
    private let syllableHintLabel = UILabel()
    private let stripView = LyricsEditorSyllableStripView()
    private let detailView = LyricsEditorSyllableDetailView()
    private let nextLyricLabel = UILabel()
    private let untimedSummaryLabel = UILabel()
    private let setTimeAndNextButton = UIButton(type: .system)
    private let stack = UIStackView()
    /// 那块打轴卡片；不是主区本身。
    private let cardGuide = UILayoutGuide()
    /// 卡片高 —— 逐行那一页 360、逐字那一页更高（多两条），所以这个数得能改。
    private var cardHeight: NSLayoutConstraint?

    /// 主键 —— 逐行打轴「打时间点并下一行」／逐字打轴「打这一字并下一字」。
    var onStampAndAdvance: (() -> Void)?

    /// 点了逐字条上第几块 —— 页面负责"选中这个字"。
    ///
    /// ⚠️ 跟逐行页那颗**同形不同义**：那边点块是"跳过去听"，这边是"选中它等着打点"。
    var onSelectSyllable: ((Int) -> Void)?

    /// 点了细条上的 `±`。
    var onNudgeSyllable: ((TimeInterval) -> Void)?

    // MARK: - 建立

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpSubviews()
        setUpConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    private func setUpSubviews() {
        backgroundColor = AppColor.pageBackground

        previousLyricLabel.font = AppFont.lyricsEditorTimingNeighbor
        previousLyricLabel.textColor = AppColor.subtitle
        previousLyricLabel.textAlignment = .center
        previousLyricLabel.numberOfLines = 2

        currentLineNumberLabel.font = AppFont.lyricsEditorTimingLineNumber
        currentLineNumberLabel.textColor = AppColor.accent
        currentLineNumberLabel.textAlignment = .center

        currentTimeLabel.font = AppFont.lyricsEditorTimingCurrentTime
        currentTimeLabel.textColor = AppColor.title
        currentTimeLabel.textAlignment = .center

        // 🔴 当前句是这一屏的主：22 半粗，就给了它这个份量。
        currentLyricLabel.font = AppFont.lyricsEditorTimingCurrentLyric
        currentLyricLabel.textColor = AppColor.title
        currentLyricLabel.textAlignment = .center
        currentLyricLabel.numberOfLines = 0

        nextLyricLabel.font = AppFont.lyricsEditorTimingNeighbor
        nextLyricLabel.textColor = AppColor.subtitle
        nextLyricLabel.textAlignment = .center
        nextLyricLabel.numberOfLines = 2

        untimedSummaryLabel.font = AppFont.lyricsEditorTimingSummary
        untimedSummaryLabel.textColor = AppColor.subtitle
        untimedSummaryLabel.textAlignment = .center

        // 🔴 主按钮：实心强调底 + 白字白图标（`setTintColor` + `backgroundColor`），
        // 不用 `Configuration.filled` 另套一层观感。
        setTimeAndNextButton.setTitle("打时间点并下一行", for: .normal)
        setTimeAndNextButton.setImage(UIImage(systemName: "target"), for: .normal)
        setTimeAndNextButton.tintColor = AppColor.onAccent
        setTimeAndNextButton.setTitleColor(AppColor.onAccent, for: .normal)
        setTimeAndNextButton.backgroundColor = AppColor.accent
        setTimeAndNextButton.layer.cornerRadius = AppMetrics.lyricsEditorPrimaryButtonCornerRadius
        setTimeAndNextButton.titleLabel?.font = AppFont.lyricsEditorPrimaryButton
        setTimeAndNextButton.addTarget(self, action: #selector(stampAndAdvanceTapped), for: .touchUpInside)

        // 🔴 逐字那两条收在一个竖栈里：藏起来的 arranged 子视图**不占位** ——
        // 逐行那一页整栈收起来，七块版式跟原来一模一样。
        syllableStack.axis = .vertical
        syllableStack.alignment = .fill
        syllableStack.spacing = 0
        syllableHintLabel.font = AppFont.lyricsEditorTimingSummary
        syllableHintLabel.textColor = AppColor.subtitle
        syllableHintLabel.textAlignment = .center
        syllableHintLabel.numberOfLines = 2
        // 🔴 有逐字标记的行本来就不多 —— 这一句只在"这一行确实没有逐字"时露出来，
        // 告诉用户为什么这一页看起来是空的（不是坏了）。
        syllableHintLabel.text = "这一行还没有逐字（正文里写 <mm:ss.xx>）"

        syllableStack.addArrangedSubview(syllableHintLabel)
        syllableStack.addArrangedSubview(stripView)
        syllableStack.addArrangedSubview(detailView)
        syllableStack.setCustomSpacing(AppMetrics.lyricsEditorSyllableStripTop, after: syllableHintLabel)
        syllableStack.setCustomSpacing(AppMetrics.lyricsEditorSyllableDetailTop, after: stripView)
        syllableStack.isHidden = true
        stripView.onTapChip = { [weak self] index in self?.onSelectSyllable?(index) }
        detailView.onNudge = { [weak self] delta in self?.onNudgeSyllable?(delta) }

        stack.axis = .vertical
        stack.spacing = AppMetrics.lyricsEditorTimingBlockSpacing
        stack.alignment = .fill
        stack.distribution = .fill
        [
            previousLyricLabel, currentLineNumberLabel, currentTimeLabel,
            currentLyricLabel, syllableStack, nextLyricLabel, untimedSummaryLabel,
            setTimeAndNextButton
        ].forEach(stack.addArrangedSubview)

        // 🔴 上一句是卡片里唯一的弹性槽：装不满时余量进这里，才有上一句到行号那截空。
        // 其余块按内容长；不靠「第一个子视图碰巧吃余量」。
        previousLyricLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
        previousLyricLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        [
            currentLineNumberLabel, currentTimeLabel, currentLyricLabel,
            nextLyricLabel, untimedSummaryLabel, setTimeAndNextButton
        ].forEach { block in
            block.setContentHuggingPriority(.required, for: .vertical)
            block.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        addLayoutGuide(cardGuide)
        addSubview(stack)
    }

    private func setUpConstraints() {
        let inset = AppMetrics.lyricsEditorTimingInset
        cardGuide.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.bottom.lessThanOrEqualToSuperview()
        }
        // 卡片高要**能改**：逐字那一页比逐行多两条。
        // 优先级 `.high`（不是 required）—— 小屏塞不下时让卡片在底部露一点，而不是在卡片里打架。
        let height = cardGuide.heightAnchor.constraint(
            equalToConstant: AppMetrics.lyricsEditorTimingCardHeight
        )
        height.priority = .defaultHigh
        height.isActive = true
        cardHeight = height
        stack.snp.makeConstraints { make in
            make.edges.equalTo(cardGuide).inset(inset)
        }
        setTimeAndNextButton.snp.makeConstraints { make in
            make.height.equalTo(AppMetrics.lyricsEditorPrimaryButtonHeight)
        }
    }

    // MARK: - 画

    /// 按草稿重画整屏，含中间时间格（行时间，不是播放头）。
    ///
    /// - Parameters:
    ///   - syllables: **光标那一行**的逐字块 —— 只有「逐字打轴」那一页用得上。
    ///   - syllableCursor: 逐字打轴里**正在打的那个字**。
    func apply(
        snapshot: LyricsEditorViewModel.Snapshot,
        format: (TimeInterval) -> String,
        untimedCount: Int,
        syllables: [LyricsEditorSyllable],
        syllableCursor: Int
    ) {
        let lines = snapshot.lines
        guard !lines.isEmpty else {
            // 一句都没有时把上下文几块留空、当句说「没有歌词」。
            previousLyricLabel.text = " "
            currentLineNumberLabel.text = " "
            currentTimeLabel.text = LyricsEditorPolicy.timeButtonTitle(for: nil)
            currentLyricLabel.text = "没有歌词"
            nextLyricLabel.text = " "
            untimedSummaryLabel.text = " "
            applySyllables(page: snapshot.timingPage, syllables: [], cursor: 0, hasLines: false)
            return
        }
        let index = snapshot.cursorIndex
        // ⚠️ 光标是 VM 夹过的（`commit` 里那一处），这里**不再夹一次** ——
        // 同一件事只许有一个地方做。
        // 🔴 上一句 / 当前句 / 下一句只显示纯歌词（与逐行页正文同一道 `plainText`）——
        // 行内 `<mm:ss>` 时间走中间格和逐字条，夹在句子里又脏又抢视线。
        previousLyricLabel.text = index > 0
            ? displayLyric(lines[index - 1].text)
            : " "
        currentLineNumberLabel.text = "第 \(index + 1) / \(lines.count) 行"
        // 🔴 中间格 = 当前行已打的轴；未打轴 `--:--`（与行 cell 同占位，空串会塌高度把上下挤在一起）。
        if let time = lines[index].time {
            currentTimeLabel.text = format(time)
        } else {
            currentTimeLabel.text = LyricsEditorPolicy.timeButtonTitle(for: nil)
        }
        let currentText = LyricsSyllableTimingPolicy.plainText(inLine: lines[index].text)
        currentLyricLabel.text = currentText.isEmpty ? "（空行）" : currentText
        nextLyricLabel.text = index + 1 < lines.count
            ? displayLyric(lines[index + 1].text)
            : " "
        untimedSummaryLabel.text = untimedCount > 0 ? "\(untimedCount) 句未打轴" : "全部已打轴"
        applySyllables(
            page: snapshot.timingPage,
            syllables: syllables,
            cursor: syllableCursor,
            lineTime: lines[index].time,
            hasLines: true
        )
    }

    /// 「逐字打轴」那一页多的那两条；逐行打轴整栈收起来，七块版式原样。
    ///
    /// 🔴 **两页的主键文案跟卡片高都收在这里** —— 别散在 `apply` 里各写一遍
    /// （漏一处就出现"逐字页上还写着逐行那颗键"）。
    private func applySyllables(
        page: LyricsEditorViewModel.TimingPage,
        syllables: [LyricsEditorSyllable],
        cursor: Int,
        lineTime: TimeInterval? = nil,
        hasLines: Bool
    ) {
        guard page == .syllable, hasLines else {
            syllableStack.isHidden = true
            setTimeAndNextButton.isEnabled = true
            setTimeAndNextButton.setTitle("打时间点并下一行", for: .normal)
            setCardHeight(AppMetrics.lyricsEditorTimingCardHeight)
            return
        }

        setCardHeight(AppMetrics.lyricsEditorTimingSyllableCardHeight)
        syllableStack.isHidden = false
        syllableHintLabel.isHidden = !syllables.isEmpty
        stripView.isHidden = syllables.isEmpty
        stripView.apply(items: syllables, activeIndex: syllables.isEmpty ? nil : cursor)
        // 这一行没有逐字 ⇒ 打不了字（连 primuse 也只对**已经有逐字**的行动作），主键灰掉。
        setTimeAndNextButton.isEnabled = !syllables.isEmpty
        // 🔴 末格是「这一行结束」那一格（正文里最后一个空块，见 `LyricsSyllableTimingPolicy` 类 doc）——
        // 文案得跟着走：在那儿还写着"并下一字"，按下去却停在原地（后面没有字可跳）。
        setTimeAndNextButton.setTitle(
            cursor == syllables.count - 1 ? "打这一行结束" : "打这一字并下一字",
            for: .normal
        )

        guard syllables.indices.contains(cursor) else {
            detailView.isHidden = true
            return
        }
        let room = LyricsSyllableTimingPolicy.nudgeRoom(
            in: syllables, at: cursor, lineTime: lineTime
        )
        detailView.isHidden = false
        detailView.apply(
            LyricsEditorSyllableDetailView.Content(
                position: cursor + 1,
                count: syllables.count,
                start: syllables[cursor].start,
                canDecrease: room.canDecrease,
                canIncrease: room.canIncrease
            )
        )
    }

    /// 卡片高只在**真的变了**才写（写一次要重排一整屏）。
    private func setCardHeight(_ value: CGFloat) {
        guard cardHeight?.constant != value else { return }
        cardHeight?.constant = value
    }

    /// 邻句展示：去掉行内逐字标记；剥完变空就留一个空格占位（栈不塌）。
    private func displayLyric(_ text: String) -> String {
        let plain = LyricsSyllableTimingPolicy.plainText(inLine: text)
        return plain.isEmpty ? " " : plain
    }

    @objc private func stampAndAdvanceTapped() { onStampAndAdvance?() }
}
