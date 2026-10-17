import SnapKit
import UIKit

/// 「编辑歌词」页底部那条 —— **两行六键**（原文模式隐藏）。
///
/// ```
/// 上一句 ↑   打点 ⏱   下一句 ↓
/// −0.5 s     ＋0.5 s   全局偏移
/// ```
///
/// 📍 版式，数值全在 `AppMetrics.lyricsEditorToolbar*` 里。
///
/// 🔴 **始终管行**（上一句 / 打点整行 / 下一句 / ±0.5s）—— 不随「逐行打轴 / 逐字打轴」换脸。
/// ⚠️ 这里说的「行」= **整行**：`±0.5s` 和「全局偏移」都把**行时间 ＋ 正文里的逐字标记**一起挪。
/// 逐字的上一字、打这一字、±0.1 走打轴面板里的主键和细条，不挤进这条工具栏。
///
/// 🔴 **微调步长 0.5 s**（不取 primuse 的 0.1 —— 那是更细的增量），
/// 写在 `AppMetrics.lyricsEditorNudgeStep`，按钮标题也从那儿取，**不写死两遍**。
final class LyricsEditorToolbar: UIStackView {

    /// 六颗键的动作。页面全接上（这一层不认识 VM、不认识播放器）。
    struct Actions {
        let previousLine: () -> Void
        let stamp: () -> Void
        let nextLine: () -> Void
        let decreaseTime: () -> Void
        let increaseTime: () -> Void
        let globalShift: () -> Void
    }

    private var actions: Actions?

    // MARK: - 建立

    init() {
        super.init(frame: .zero)
        setUpSubviews()
    }

    /// 🔴 `UIStackView` 的 `init(coder:)` 在 SDK 里是**非可选**的（`UIStackView.h:127`
    /// `NS_DESIGNATED_INITIALIZER`），所以这里既不能写 `init?` 也不能 `return nil` —— 只能 fatal。
    /// ⇒ 全工程**唯一一处**该留 `fatalError` 的地方：宪法 §三·零容忍 1 要的 `assertionFailure`
    /// 在非可失败初始化器里写不出来（那里必须有一条 `Never` 收尾）。`@available(*, unavailable)`
    /// 让 Swift 调用方**编译期就调不到它**，所以这段崩只在「nib 硬解档」时才可能发生。
    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("界面全部用代码搭，不会从 xib / storyboard 解档")
    }

    /// 接上六颗键的动作。**必须在建控件之后调**（`addTarget`，同一件事）。
    func connect(_ actions: Actions) {
        self.actions = actions
    }

    private func setUpSubviews() {
        axis = .vertical
        spacing = AppMetrics.lyricsEditorToolbarRowSpacing
        backgroundColor = AppColor.pageBackground
        isLayoutMarginsRelativeArrangement = true
        layoutMargins = UIEdgeInsets(
            top: AppMetrics.lyricsEditorToolbarVerticalInset,
            left: AppMetrics.lyricsEditorToolbarSideInset,
            bottom: AppMetrics.lyricsEditorToolbarVerticalInset,
            right: AppMetrics.lyricsEditorToolbarSideInset
        )
        addArrangedSubview(
            row([
                button(title: "上一句", image: "chevron.up", action: #selector(previousLineTapped)),
                button(title: "打点", image: "timer", action: #selector(stampTapped)),
                button(title: "下一句", image: "chevron.down", action: #selector(nextLineTapped))
            ])
        )
        // 🔴 标题里的 ±0.5 **从 `AppMetrics` 取**，不另写一遍字符串 ——
        // 步长一改，两处会走散（而这种漂移没人会当场发现）。
        let step = AppMetrics.lyricsEditorNudgeStep
        addArrangedSubview(
            row([
                button(title: "-\(Self.offsetLabel(step))s", image: "minus", action: #selector(decreaseTapped)),
                button(title: "+\(Self.offsetLabel(step))s", image: "plus", action: #selector(increaseTapped)),
                button(title: "全局偏移", image: "clock.arrow.circlepath", action: #selector(globalShiftTapped))
            ])
        )
    }

    private func row(_ buttons: [UIButton]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: buttons)
        stack.axis = .horizontal
        stack.spacing = AppMetrics.lyricsEditorToolbarButtonSpacing
        stack.distribution = .fillEqually
        return stack
    }

    private func button(title: String, image: String, action: Selector) -> UIButton {
        // 🔴 系统键 + tint 强调色（字+图标）+ `frd_black8` 浅底 + 圆角 8。
        // 不用 `Configuration` —— 它会把整块底做成「框暗」；要的是「字暗」。
        // 打轴主键同一套搭法（颜色不同：那颗是强调底白字）。
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setImage(UIImage(systemName: image), for: .normal)
        button.tintColor = AppColor.accent
        button.setTitleColor(AppColor.accent, for: .normal)
        button.backgroundColor = AppColor.surface
        button.layer.cornerRadius = AppMetrics.lyricsEditorToolbarButtonCornerRadius
        button.titleLabel?.font = AppFont.lyricsEditorToolbarButton
        button.addTarget(self, action: action, for: .touchUpInside)
        button.snp.makeConstraints { make in
            make.height.equalTo(AppMetrics.lyricsEditorToolbarButtonHeight)
        }
        return button
    }

    /// 步长的字面写法：**去掉多余的零**（0.5 → "0.5"，0.10 → "0.1"）。
    private static func offsetLabel(_ value: TimeInterval) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%g", value)
    }

    // MARK: - 事件

    @objc private func previousLineTapped() { actions?.previousLine() }
    @objc private func stampTapped() { actions?.stamp() }
    @objc private func nextLineTapped() { actions?.nextLine() }
    @objc private func decreaseTapped() { actions?.decreaseTime() }
    @objc private func increaseTapped() { actions?.increaseTime() }
    @objc private func globalShiftTapped() { actions?.globalShift() }
}
