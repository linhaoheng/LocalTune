import PanModal
import SnapKit
import UIKit

/// 歌词显示设置面板 —— 盖在播放页上的**小弹层**。
///
/// ```
/// ──── 歌词显示设置 ────
///  对齐方式
///  [ ⬅ | ⬌ | ➡ ]
///  ─────────────────
///  文字大小        18
///  ●──────────────
///        关闭
/// ```
///
/// **内容**：
/// 段序「对齐方式 → 文字大小」、标题「歌词显示设置」、字号 **16–36 默认 18**、
/// 各段间距与控件高（数值与出处全在 `AppMetrics` 的「歌词设置面板」那一节）。
///
/// **弹出形态照队列页**（`QueueViewController` 末尾那段 `PanModalPresentable`）——
/// 顶部圆角 / 弹簧 / 往下拖走 / 点面板外关，都交给 `PanModal`；本页只写跟库默认不一样的几条。
///
/// ⚠️ **"跟歌词区同盒的卡片"那一套一概不用**：那种面板是（圆角 20 / 两侧内缩 8 /
/// 贴底 −15 / `alpha ＋ scale` 淡入）—— 那是**卡片**形态的量，搬到"底部弹层"上就是错的
/// ⚠️ 也**不做时间偏移**那一段。
///
/// ## 它不碰设置、也不认识播放器
///
/// 进来收一份 `appearance`，用户一改就把**整份新值**通过 `onAppearanceChange` 报出去 ——
/// 写 `AppSettings`、把新值应用到歌词列表，都是**上面那页**的事。
/// 🔴 回调走 `init` 必传的 `let`（宪法 §三·动作与状态 5：可选回调漏接**编译不出声**，
/// 表现就是"拖了滑杆没反应"）。
final class LyricsSettingsViewController: BaseViewController {

    // MARK: - 依赖

    /// 用户改了字号 / 对齐 —— 报出**整份新值**（不是"哪个键变了"）。
    private let onAppearanceChange: (LyricsAppearance) -> Void

    /// 现在这份 —— 面板自己的底稿。
    ///
    /// ⚠️ 它**不是第二份真相**（真相在 `AppSettings`）：只是一次拖动还没结束时，
    /// 用来算"下一份是什么"的当前值 —— `LyricsAppearance` 是值类型，
    /// 手上没有当前值就推不出"只改了字号、对齐照旧"。
    private var appearance: LyricsAppearance

    // MARK: - 零件

    private let alignControl = UISegmentedControl()
    private let fontSlider = UISlider()
    private let fontValueLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    // MARK: - 建立

    init(appearance: LyricsAppearance, onAppearanceChange: @escaping (LyricsAppearance) -> Void) {
        self.appearance = appearance
        self.onAppearanceChange = onAppearanceChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 🔴 面板的底是**毛玻璃**（下面那层 blur），不能让基类那个浅色页底露出来。
        view.backgroundColor = .clear
        layout()
        wireActions()
        present(appearance)
    }

    // MARK: - 布局

    private func layout() {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        view.addSubview(blur)
        blur.snp.makeConstraints { $0.edges.equalToSuperview() }

        let header = makeHeader()
        let alignTitle = makeSectionTitle("对齐方式")
        let divider = makeHairline()
        let fontTitle = makeSectionTitle("文字大小")

        alignControl.backgroundColor = AppColor.overlayFill
        alignControl.selectedSegmentTintColor = AppColor.overlayTint
        // ⚠️ 段里放的是**模板图**（SF Symbol），它跟着控件的 `tintColor` 上色 ——
        // 不给就是系统强调色（蓝），压在深色毛玻璃上很跳。
        alignControl.tintColor = AppColor.overlayText
        for (index, alignment) in LyricsAlignment.allCases.enumerated() {
            alignControl.insertSegment(
                with: Self.segmentImage(for: alignment), at: index, animated: false
            )
        }

        fontValueLabel.font = AppFont.lyricsSettingsValue
        fontValueLabel.textColor = AppColor.overlayText
        fontValueLabel.textAlignment = .right

        fontSlider.minimumValue = Float(LyricsAppearance.fontSizeRange.lowerBound)
        fontSlider.maximumValue = Float(LyricsAppearance.fontSizeRange.upperBound)
        fontSlider.isContinuous = true
        fontSlider.minimumTrackTintColor = AppColor.accent
        fontSlider.maximumTrackTintColor = AppColor.overlayBorder
        fontSlider.setThumbImage(Self.sliderThumb(), for: .normal)
        fontSlider.setThumbImage(Self.sliderThumb(), for: .highlighted)

        var close = UIButton.Configuration.plain()
        close.attributedTitle = AttributedString(
            "关闭",
            attributes: AttributeContainer([
                .font: AppFont.lyricsSettingsCloseTitle,
                .foregroundColor: AppColor.overlayTextTertiary
            ])
        )
        close.contentInsets = NSDirectionalEdgeInsets(
            top: AppMetrics.s18, leading: AppMetrics.s15,
            bottom: AppMetrics.s18, trailing: AppMetrics.s15
        )
        closeButton.configuration = close

        for part in [header, alignTitle, alignControl, divider, fontTitle, fontValueLabel,
                     fontSlider, closeButton] {
            view.addSubview(part)
        }

        // 🔴 这一串数**必须**和 `AppMetrics.lyricsSettingsContentHeight` 那个和相等 ——
        // 面板上下两头都钉死了（顶=标题条、底=安全区上沿），和不对会当场打约束冲突的日志。
        let inset = AppMetrics.lyricsSettingsSideInset
        header.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(AppMetrics.lyricsSettingsHeaderHeight)
        }
        alignTitle.snp.makeConstraints { make in
            make.top.equalTo(header.snp.bottom).offset(AppMetrics.lyricsSettingsFirstSectionTop)
            make.leading.equalToSuperview().offset(inset)
            make.height.equalTo(AppMetrics.lyricsSettingsSectionTitleHeight)
        }
        alignControl.snp.makeConstraints { make in
            make.top.equalTo(alignTitle.snp.bottom)
                .offset(AppMetrics.lyricsSettingsSectionControlTop)
            make.leading.trailing.equalToSuperview().inset(inset)
            make.height.equalTo(AppMetrics.lyricsSettingsAlignControlHeight)
        }
        divider.snp.makeConstraints { make in
            make.top.equalTo(alignControl.snp.bottom).offset(AppMetrics.lyricsSettingsDividerTop)
            make.leading.trailing.equalToSuperview().inset(inset)
        }
        fontTitle.snp.makeConstraints { make in
            make.top.equalTo(divider.snp.bottom).offset(AppMetrics.lyricsSettingsSecondSectionTop)
            make.leading.equalToSuperview().offset(inset)
            make.height.equalTo(AppMetrics.lyricsSettingsSectionTitleHeight)
        }
        fontValueLabel.snp.makeConstraints { make in
            make.centerY.equalTo(fontTitle)
            make.trailing.equalToSuperview().inset(inset)
        }
        fontSlider.snp.makeConstraints { make in
            make.top.equalTo(fontTitle.snp.bottom).offset(AppMetrics.lyricsSettingsSliderTop)
            make.leading.trailing.equalToSuperview().inset(inset)
            make.height.equalTo(AppMetrics.lyricsSettingsSliderHeight)
        }
        closeButton.snp.makeConstraints { make in
            make.top.equalTo(fontSlider.snp.bottom).offset(AppMetrics.lyricsSettingsCloseTop)
            make.centerX.equalToSuperview()
            make.height.equalTo(AppMetrics.lyricsSettingsCloseHeight)
            // 🔴 底边 = **安全区上沿**：`longFormHeight` 那份高度里已经含了底部安全区，
            // 所以关闭键落在 home 指示条上方，不压它。
            make.bottom.equalTo(view.safeAreaLayoutGuide.snp.bottom)
        }
    }

    /// 标题条：「歌词显示设置」＋ 底边一条细线（`headerView` 那条 `qmui_borderPosition = .bottom`）。
    private func makeHeader() -> UIView {
        let header = UIView()

        let title = UILabel()
        title.text = "歌词显示设置"
        title.font = AppFont.lyricsSettingsTitle
        title.textColor = AppColor.nowPlayingSolid
        title.textAlignment = .center
        header.addSubview(title)
        title.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(AppMetrics.lyricsSettingsTitleInset)
            make.top.bottom.equalToSuperview()
        }

        let line = makeHairline()
        header.addSubview(line)
        line.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
        }
        return header
    }

    private func makeSectionTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = AppFont.lyricsSettingsSectionTitle
        label.textColor = AppColor.overlayText
        return label
    }

    /// 一条细线（标题条底边 / 两段之间）—— `qmui_borderPosition` / 一个 1 点高的 `UIView`。
    ///
    /// ⚠️ 高取 `AppMetrics.borderWidth`（**1**）而**不是** `1 / displayScale`：面板总高是个算准的和
    /// （`AppMetrics.lyricsSettingsContentHeight`），线宽跟着屏幕倍数变会让那个和对不上。
    private func makeHairline() -> UIView {
        let line = UIView()
        line.backgroundColor = AppColor.overlaySeparator
        line.isUserInteractionEnabled = false
        line.snp.makeConstraints { $0.height.equalTo(AppMetrics.borderWidth) }
        return line
    }

    /// 滑杆那颗白圆 —— **纯白实心圆**。
    ///
    /// 🔴 用 `nowPlayingSolid`（不掺 alpha 的**实白**），跟播放页那颗圆点同一个理由：
    /// `overlay*` 那一家全是**半透明白**，压在毛玻璃上会透出底色。要纯白圆点。
    private static func sliderThumb() -> UIImage {
        let side = AppMetrics.lyricsSettingsSliderThumbDiameter
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            AppColor.nowPlayingSolid.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
        }
    }

    // MARK: - 接线

    private func wireActions() {
        alignControl.addTarget(self, action: #selector(alignmentChanged), for: .valueChanged)
        fontSlider.addTarget(self, action: #selector(fontSliding), for: .valueChanged)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    }

    /// 把一份外观摆到控件上 —— **进场一次**，以及**滑动的每一次**（含"值没变"的那几次）。
    ///
    /// 🔴 **为什么滑动时也得调它**：取整只保证**数**是整数，**滑块拇指的位**得靠这里拉回整数格。
    /// 手指松在 16.4 处时取整仍是 16 ⇒ 值与当前相同 ⇒ 不走 `update` ⇒ 拇指就留在两格之间
    /// （看着像"能滑小数"）。所以对账放在判断**之前**。
    private func present(_ appearance: LyricsAppearance) {
        fontSlider.setValue(Float(appearance.fontSize), animated: false)
        fontValueLabel.text = Self.fontValueText(appearance.fontSize)
        alignControl.selectedSegmentIndex = Self.segmentIndex(for: appearance.alignment)
    }

    // MARK: - 动作

    /// 收起面板 —— 跟往下拖走、点面板外是同一件事，所以**不走 `AppRouter`**（同队列页那颗关闭键）。
    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func alignmentChanged() {
        update(LyricsAppearance(fontSize: appearance.fontSize,
                                alignment: Self.alignment(forSegment: alignControl.selectedSegmentIndex)))
    }

    /// 滑杆拖动 —— **实时**。
    ///
    /// ⚠️ **不节流**：列表那边自己会"重排 ＋ 锚住用户正在看的那一行"，节流只会让手感变钝。
    /// ⚠️ **不做触觉反馈**：工程里**一处** `UIFeedbackGenerator` 都没有（播放页也显式关掉了
    /// 库自带的那一下），一路震跟全 App 的取态不一致。别加那句 `UISelectionFeedbackGenerator`。
    @objc private func fontSliding() {
        update(LyricsAppearance(fontSize: CGFloat(fontSlider.value), alignment: appearance.alignment))
    }

    /// 落地一份新外观 —— **① 先把控件摆成它 → ② 真变了才记下并上报**（写设置 ＋ 应用到歌词列表）。
    ///
    /// 🔴 **① 必须无条件、且在 ② 之前**：取整只保证**数**是整数，**滑块拇指的位**得靠 `present` 拉回整数格。
    /// 手指松在 16.4 处时取整仍是 16 ⇒ 值与当前相同 ⇒ 若不先摆，拇指出不了那两格之间（看着像"能滑小数"）。
    private func update(_ newAppearance: LyricsAppearance) {
        present(newAppearance)
        guard newAppearance != appearance else { return }
        appearance = newAppearance
        onAppearanceChange(newAppearance)
    }

    // MARK: - 值 ↔ 段（唯一一处对应表）

    private static func fontValueText(_ fontSize: CGFloat) -> String {
        String(Int(fontSize.rounded()))
    }

    /// 段序 = `LyricsAlignment.allCases` 的顺序（左 / 中 / 右）—— 段子是照 `allCases` 建的，
    /// 所以这里也照它查，**不另写一套下标**（另写一套就会在有人调换声明顺序时对不上）。
    private static func segmentIndex(for alignment: LyricsAlignment) -> Int {
        LyricsAlignment.allCases.firstIndex(of: alignment) ?? 0
    }

    private static func alignment(forSegment index: Int) -> LyricsAlignment {
        let cases = LyricsAlignment.allCases
        guard cases.indices.contains(index) else { return .center }
        return cases[index]
    }

    /// 三段的图标 —— 三枚 SF Symbol。
    private static func segmentImage(for alignment: LyricsAlignment) -> UIImage? {
        let name: String
        switch alignment {
        case .left: name = "text.alignleft"
        case .center: name = "text.aligncenter"
        case .right: name = "text.alignright"
        }
        return UIImage(systemName: name)
    }
}

// MARK: - 弹出形态

/// 小弹层、贴底、按内容高 —— 只写跟库默认不一样的那几条（同 `QueueViewController` 那段）。
extension LyricsSettingsViewController: PanModalPresentable {

    /// 面板里**没有可滚的东西**（滑杆不是滚动视图）—— 按 PanModal 官方那条：
    /// 没有可滚列表就返回 `nil`。
    ///
    /// ⚠️ 这一条**库没给默认实现**（`PanModalPresentable+Defaults` 里独缺它），必须写 ——
    /// 不写编译就报"不符合协议"。
    /// 给 `nil` ⇒ 库不做"列表 ↔ 弹层"的交接（这面板也没得交接），也**不会**去 KVO 谁、
    /// 不会去改谁的滚动指示条（同播放页那条的由来）。
    var panScrollable: UIScrollView? { nil }

    /// 高度 = **内容高 ＋ 底部安全区**。
    ///
    /// 🔴 `.contentHeight(_:)` 这个档位就是"库自己再把底部安全区加上"
    /// （`PanModalPresentable+LayoutHelpers.topMargin(from:)`：`bottomYPos − (height ＋ bottomLayoutOffset)`），
    /// 所以这里给的只是**内容**那一段 —— 值和它的由来在 `AppMetrics.lyricsSettingsContentHeight`。
    var longFormHeight: PanModalHeight {
        .contentHeight(AppMetrics.lyricsSettingsContentHeight)
    }

    /// 顶部圆角 —— 跟队列半屏同一档（值在 `AppMetrics.lyricsSettingsSheetCornerRadius`）。
    var shouldRoundTopCorners: Bool { true }

    var cornerRadius: CGFloat { AppMetrics.lyricsSettingsSheetCornerRadius }

    /// 不要顶部那条小横条 —— 跟队列页一致。
    var showDragIndicator: Bool { false }

    /// 外面**不压暗**：面板外是透明的，播放页照常看得见。
    var panModalBackgroundColor: UIColor { .clear }

    /// 不震 —— 同播放页 / 队列页（理由写在 `NowPlayingViewController` 那条上）。
    var isHapticFeedbackEnabled: Bool { false }

    /// 升起 / 收起 / 拖回都不过冲 —— 跟队列页同一个弹簧（0.3 秒、不过冲）。
    /// 关闭、吸附两档库默认跟这一档走，所以只写这一处。
    var presentationSpring: PanModalSpring { PanModalSpring(response: 0.3, damping: 1) }
}
