import SnapKit
import UIKit

/// 前级：整条曲线一起升降。横滑，不进十条竖条那一排。
final class EQPreampRow: UIView {

    var onChange: ((Float) -> Void)?

    private let nameLabel = UILabel()
    private let slider = UISlider()
    private let valueLabel = UILabel()
    private var suppress = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        nameLabel.text = "前级增益"
        nameLabel.font = AppFont.equalizerHeaderAction
        nameLabel.textColor = AppColor.overlayTextSecondary
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)

        valueLabel.font = AppFont.equalizerBandLabel
        valueLabel.textColor = AppColor.nowPlayingSolid
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        EQGainSliderStyle.apply(to: slider)
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)

        addSubview(nameLabel)
        addSubview(slider)
        addSubview(valueLabel)
        nameLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.centerY.equalToSuperview()
        }
        valueLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview()
            make.centerY.equalToSuperview()
            make.width.greaterThanOrEqualTo(AppMetrics.equalizerPreampValueMinWidth)
        }
        slider.snp.makeConstraints { make in
            make.leading.equalTo(nameLabel.snp.trailing).offset(AppMetrics.equalizerPreampGap)
            make.trailing.equalTo(valueLabel.snp.leading).offset(-AppMetrics.equalizerPreampGap)
            make.centerY.equalToSuperview()
        }
    }

    required init?(coder: NSCoder) {
        // 本行只由代码构造 —— 从 nib / storyboard 解档是写错了：调试期当场停下，正式版返回 nil。
        assertionFailure("EQPreampRow 只由代码构造，不该走 init(coder:)")
        return nil
    }

    func setGain(_ value: Float) {
        suppress = true
        slider.value = value
        suppress = false
        valueLabel.text = Self.display(value)
    }

    @objc private func sliderChanged() {
        let value = EQGainSliderStyle.rounded(slider.value)
        slider.value = value
        valueLabel.text = Self.display(value)
        guard !suppress else { return }
        onChange?(value)
    }

    private static func display(_ value: Float) -> String {
        "\(EQGainSliderStyle.display(value)) dB"
    }
}
