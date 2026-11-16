import SnapKit
import UIKit

/// 横滑预设卡。选中只走描边；按下不铺系统高亮。
final class EQPresetCell: UICollectionViewCell {

    static let reuseID = "eqPreset"

    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let iconView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        automaticallyUpdatesBackgroundConfiguration = false
        backgroundConfiguration = .clear()
        contentView.backgroundColor = .secondarySystemFill
        contentView.layer.cornerRadius = AppMetrics.equalizerCardCorner
        contentView.layer.borderWidth = AppMetrics.equalizerCardBorderWidth
        contentView.clipsToBounds = true
        titleLabel.font = AppFont.equalizerPresetTitle
        titleLabel.textColor = AppColor.nowPlayingSolid
        statusLabel.font = AppFont.equalizerPresetStatus
        iconView.image = UIImage(
            systemName: "slider.vertical.3",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        )
        iconView.tintColor = AppColor.overlayTint
        contentView.addSubview(titleLabel)
        contentView.addSubview(statusLabel)
        contentView.addSubview(iconView)
        let pad = AppMetrics.equalizerCardPadding
        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(pad)
            make.top.equalToSuperview().offset(pad)
            make.trailing.equalToSuperview().offset(-pad)
        }
        statusLabel.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel)
            make.bottom.equalToSuperview().offset(-pad)
        }
        iconView.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-pad)
            make.bottom.equalToSuperview().offset(-pad)
        }
    }

    required init?(coder: NSCoder) {
        // 本行只由代码构造 —— 从 nib / storyboard 解档是写错了：调试期当场停下，正式版返回 nil。
        assertionFailure("EQPresetCell 只由代码构造，不该走 init(coder:)")
        return nil
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        backgroundConfiguration = .clear()
    }

    func show(title: String, selected: Bool, showsIcon: Bool) {
        titleLabel.text = title
        statusLabel.text = selected ? "已选中" : "选择"
        statusLabel.textColor = selected ? AppColor.overlayTint : AppColor.accent
        contentView.layer.borderColor = selected ? AppColor.accent.cgColor : UIColor.clear.cgColor
        iconView.isHidden = !showsIcon
    }
}
