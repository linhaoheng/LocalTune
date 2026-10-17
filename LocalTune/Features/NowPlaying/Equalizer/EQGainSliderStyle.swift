import UIKit

/// 十条竖滑条和前级横滑条共用的皮：行程、圆点、取整显示。
enum EQGainSliderStyle {

    static func apply(to slider: UISlider) {
        slider.minimumValue = EQSpec.minGain
        slider.maximumValue = EQSpec.maxGain
        slider.minimumTrackTintColor = AppColor.accent
        slider.maximumTrackTintColor = AppColor.overlayBorder
        slider.setThumbImage(thumbImage, for: .normal)
        slider.setThumbImage(thumbImage, for: .highlighted)
    }

    static func display(_ value: Float) -> String {
        String(Int(value.rounded()))
    }

    static func rounded(_ value: Float) -> Float {
        value.rounded()
    }

    private static let thumbImage: UIImage = {
        let size = AppMetrics.equalizerThumbSide
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            AppColor.nowPlayingSolid.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).fill()
        }
    }()
}
