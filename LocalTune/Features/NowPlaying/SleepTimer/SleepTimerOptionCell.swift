import SnapKit
import UIKit

/// 档位行：标题，倒计时跟在标题后面。勾走系统 `accessoryType`，不自绘。
final class SleepTimerOptionCell: UITableViewCell {

    static let reuseID = "sleepOption"

    private let titleLabel = UILabel()
    private let remainingLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        titleLabel.font = AppFont.songTitle
        titleLabel.textColor = AppColor.title
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        remainingLabel.font = AppFont.sleepTimerRemaining
        remainingLabel.textColor = AppColor.subtitle
        remainingLabel.setContentHuggingPriority(.required, for: .horizontal)
        contentView.addSubview(titleLabel)
        contentView.addSubview(remainingLabel)
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(contentView.layoutMarginsGuide)
            make.top.bottom.equalTo(contentView.layoutMarginsGuide)
        }
        remainingLabel.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel.snp.trailing).offset(AppMetrics.s10)
            make.centerY.equalTo(titleLabel)
            make.trailing.lessThanOrEqualTo(contentView.layoutMarginsGuide)
        }
    }

    required init?(coder: NSCoder) {
        // 本行只由代码构造 —— 从 nib / storyboard 解档是写错了：调试期当场停下，正式版返回 nil。
        assertionFailure("SleepTimerOptionCell 只由代码构造，不该走 init(coder:)")
        return nil
    }

    func show(title: String, remaining: String?) {
        titleLabel.text = title
        remainingLabel.text = remaining
        remainingLabel.isHidden = remaining == nil
    }
}
