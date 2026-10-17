import SnapKit
import UIKit

/// 「当前字」细条 —— `k/n` ＋ 这个字的起点 ＋ `±` 微调。
///
/// 两处用**同一份**：逐行页的当前行、打轴页的「逐字打轴」。
///
/// 📍 版式照工作台 `adjustmentRow` 写：**整条没有底板**（高 26），
/// 左边 `waveform` 图标 ＋ `k/n` ＋ 起点时刻，右边一对 **30 × 24** 的小键画
/// `minus` / `plus` 图标 —— 步长的数字（±0.1）只活在无障碍标签里。
///
/// 🔴 起点时刻是**只读字**（工作台 `Text`），不可点；跳转听走逐字块本身。
/// 🔴 **两个 `±` 的到界状态由调用方算**（`canDecrease` / `canIncrease`）——
/// 到界看邻字 **和** 句子时间（`LyricsSyllableTimingPolicy.nudgeRoom`），这一层手上只有当前字。
final class LyricsEditorSyllableDetailView: UIView {

    /// 这一刻要画的东西。
    struct Content: Equatable {
        /// 第几个字（**1-based**，给人看的）。
        var position: Int
        /// 这一行一共几个字。
        var count: Int
        /// 这个字的起点。
        var start: TimeInterval
        /// 还能往前挪（前一个字没顶住）。
        var canDecrease: Bool
        /// 还能往后挪（后一个字没顶住）。
        var canIncrease: Bool
    }

    /// 点了 `±` —— 递出这一下要挪多少秒。
    var onNudge: ((TimeInterval) -> Void)?

    private let iconView = UIImageView()
    private let positionLabel = UILabel()
    /// 工作台是 `Text`：只显示、不可点，换字无按钮动画。
    private let timeLabel = UILabel()
    private let decreaseButton = UIButton(type: .system)
    private let increaseButton = UIButton(type: .system)

    /// 最左那颗波形 —— **字号由这里定**（`pointSize` 不是"画出来多大"，见 `AppMetrics` 里那一条）。
    private static let iconSymbol = UIImage.SymbolConfiguration(
        pointSize: AppMetrics.lyricsEditorSyllableDetailIconPointSize,
        weight: .semibold
    )

    /// 两颗小键面上的 `minus` / `plus` —— 同一套符号配置（工作台 10 半粗）。
    private static let nudgeSymbol = UIImage.SymbolConfiguration(
        pointSize: AppMetrics.lyricsEditorSyllableDetailButtonIconPointSize,
        weight: .semibold
    )

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

    // MARK: - 建立

    private func setUpSubviews() {
        // 🔴 **整条没有底板**（连圆角也不切）：底只在两颗小键上。细条跟字块同在正文那一列里，
        // 铺一块底就成了"行里行"，在「当前句」的淡染上尤其难看。
        backgroundColor = .clear

        iconView.image = UIImage(systemName: "waveform", withConfiguration: Self.iconSymbol)
        iconView.tintColor = AppColor.lyricsEditorAccent
        // ⚠️ `.center` 不 `.scaleAspectFit` —— 后者会把小于方框的图**放大**去填满，
        // 定的字号就白定了（见 `AppMetrics.lyricsEditorSyllableDetailIconPointSize`）。
        iconView.contentMode = .center

        positionLabel.font = AppFont.lyricsEditorSyllableDetailIndex
        positionLabel.textColor = AppColor.secondaryText

        timeLabel.font = AppFont.lyricsEditorSyllableDetailTime
        timeLabel.textColor = AppColor.secondaryText

        // 🔴 两颗小键画 **图标不画字**（工作台 `systemImage: minus / plus`）：
        // 时刻在左边已经印了一遍，键面上再写一遍 `-0.1`，一行里三个数字抢眼睛。
        for (button, symbol) in [(decreaseButton, "minus"), (increaseButton, "plus")] {
            button.setImage(UIImage(systemName: symbol, withConfiguration: Self.nudgeSymbol), for: .normal)
            button.tintColor = AppColor.title
            button.accessibilityLabel = symbol == "minus"
                ? "提前 \(Self.stepLabel(AppMetrics.lyricsEditorSyllableNudgeStep)) 秒"
                : "延后 \(Self.stepLabel(AppMetrics.lyricsEditorSyllableNudgeStep)) 秒"
            button.backgroundColor = AppColor.lyricsEditorNudgeButtonFill
            button.layer.cornerRadius = AppMetrics.lyricsEditorSyllableDetailButtonCornerRadius
            button.layer.cornerCurve = .continuous
        }
        decreaseButton.setTitleColor(AppColor.subtitle, for: .disabled)
        decreaseButton.addTarget(self, action: #selector(decreaseTapped), for: .touchUpInside)
        increaseButton.addTarget(self, action: #selector(increaseTapped), for: .touchUpInside)

        [iconView, positionLabel, timeLabel, decreaseButton, increaseButton]
            .forEach(addSubview)
    }

    private func setUpConstraints() {
        let gap = AppMetrics.lyricsEditorSyllableDetailItemSpacing

        // 🔴 高由这里定死：三段都是定高的件，让它们自己撑出来会随字体上下抖。
        let height = heightAnchor.constraint(
            equalToConstant: AppMetrics.lyricsEditorSyllableDetailHeight
        )
        height.isActive = true

        // 最左图标贴正文列左沿；`±` 右沿内缩一截（见 `lyricsEditorSyllableDetailTrailingInset`）。
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.centerY.equalToSuperview()
            make.width.height.equalTo(AppMetrics.lyricsEditorSyllableDetailIconSide)
        }
        positionLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(gap)
            make.centerY.equalToSuperview()
        }
        timeLabel.snp.makeConstraints { make in
            make.leading.equalTo(positionLabel.snp.trailing).offset(gap)
            make.centerY.equalToSuperview()
        }
        increaseButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview()
                .offset(-AppMetrics.lyricsEditorSyllableDetailTrailingInset)
            make.centerY.equalToSuperview()
            make.width.equalTo(AppMetrics.lyricsEditorSyllableDetailButtonWidth)
            make.height.equalTo(AppMetrics.lyricsEditorSyllableDetailButtonHeight)
        }
        decreaseButton.snp.makeConstraints { make in
            make.trailing.equalTo(increaseButton.snp.leading)
                .offset(-AppMetrics.lyricsEditorSyllableDetailButtonSpacing)
            make.centerY.equalToSuperview()
            make.width.equalTo(AppMetrics.lyricsEditorSyllableDetailButtonWidth)
            make.height.equalTo(AppMetrics.lyricsEditorSyllableDetailButtonHeight)
        }
    }

    // MARK: - 摆

    func apply(_ content: Content) {
        // 工作台原文是 `k/n`（无空格）—— `caption2` 那一档本来就挤，加空格会跟时刻抢位。
        positionLabel.text = "\(content.position)/\(content.count)"
        timeLabel.text = LyricsEditorPolicy.format(content.start)
        decreaseButton.isEnabled = content.canDecrease
        increaseButton.isEnabled = content.canIncrease
    }

    /// 无障碍标签里步长的字面写法：**去掉多余的零**（0.1 → "0.1"，1.0 → "1"）。
    private static func stepLabel(_ value: TimeInterval) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%g", value)
    }

    // MARK: - 事件

    @objc private func decreaseTapped() { onNudge?(-AppMetrics.lyricsEditorSyllableNudgeStep) }
    @objc private func increaseTapped() { onNudge?(AppMetrics.lyricsEditorSyllableNudgeStep) }
}
