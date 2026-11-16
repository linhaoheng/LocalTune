import UIKit

/// 一根竖滑条。行程 ±12；程序改值时不回写 Session。
final class EQBandColumn: UIView {

    var onChange: ((Float) -> Void)?

    private let valueLabel = UILabel()
    private let slider = UISlider()
    private let freqLabel = UILabel()
    private var suppress = false

    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = AppColor.nowPlayingBackground
        valueLabel.font = AppFont.equalizerBandLabel
        valueLabel.textColor = AppColor.nowPlayingSolid
        valueLabel.textAlignment = .center
        freqLabel.font = AppFont.equalizerBandLabel
        freqLabel.textColor = AppColor.nowPlayingSolid
        freqLabel.textAlignment = .center
        freqLabel.text = title

        EQGainSliderStyle.apply(to: slider)
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.transform = CGAffineTransform(rotationAngle: -.pi / 2)

        addSubview(valueLabel)
        addSubview(slider)
        addSubview(freqLabel)
    }

    required init?(coder: NSCoder) {
        // 本行只由代码构造 —— 从 nib / storyboard 解档是写错了：调试期当场停下，正式版返回 nil。
        assertionFailure("EQBandColumn 只由代码构造，不该走 init(coder:)")
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let labelH = AppMetrics.equalizerBandLabelHeight
        valueLabel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: labelH)
        freqLabel.frame = CGRect(
            x: 0, y: bounds.height - labelH, width: bounds.width, height: labelH
        )
        let travel = AppMetrics.equalizerBandSliderTravel
        let thickness = AppMetrics.equalizerThumbSide
        slider.bounds = CGRect(x: 0, y: 0, width: travel, height: thickness)
        slider.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func setGain(_ value: Float) {
        suppress = true
        slider.value = value
        suppress = false
        valueLabel.text = EQGainSliderStyle.display(value)
    }

    @objc private func sliderChanged() {
        let value = EQGainSliderStyle.rounded(slider.value)
        slider.value = value
        valueLabel.text = EQGainSliderStyle.display(value)
        guard !suppress else { return }
        onChange?(value)
    }
}
