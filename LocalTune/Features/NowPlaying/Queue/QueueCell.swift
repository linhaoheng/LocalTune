import SnapKit
import UIKit

/// 队列页的一行：**[声波] 歌名 ………… ×**。
///
/// 样子（`PlayingCell`）：只有歌名一行；
/// 当前格歌名变强调色、前面让出一组声波；行尾一颗 ×。
///
/// ⚠️ × 只报"被点了"，**不知道自己是第几行** —— 行号在点下那一刻由页面问表格要
/// （走 `indexPathForCell:`）：行会被删、会挪，记在 cell 上的行号迟早过期。
final class QueueCell: UITableViewCell {

    static let reuseID = "QueueCell"

    /// × 被点了。
    var onDelete: (() -> Void)?

    private let playingBars = PlayingBarsView()
    private let titleLabel = UILabel()
    private let deleteButton = UIButton(type: .system)

    /// 歌名的左边距 —— 当前格要往右让出声波的位置。
    private var titleLeading: Constraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = AppColor.queueSelection
        selectedBackgroundView = selected

        titleLabel.font = AppFont.queueRowTitle
        titleLabel.lineBreakMode = .byTruncatingTail

        deleteButton.setImage(
            UIImage(
                systemName: "xmark",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: AppMetrics.queueDeleteIconPointSize, weight: .semibold
                )
            ),
            for: .normal
        )
        deleteButton.tintColor = AppColor.overlayTextTertiary
        deleteButton.accessibilityLabel = "移出队列"
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)

        for part in [playingBars, titleLabel, deleteButton] {
            contentView.addSubview(part)
        }
        playingBars.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(AppMetrics.s15)
            make.centerY.equalToSuperview()
            make.size.equalTo(AppMetrics.queuePlayingIndicatorSide)
        }
        deleteButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-AppMetrics.s15)
            make.top.bottom.equalToSuperview()
            make.width.equalTo(AppMetrics.queueDeleteButtonWidth)
        }
        titleLabel.snp.makeConstraints { make in
            titleLeading = make.leading.equalToSuperview().offset(AppMetrics.s15).constraint
            make.centerY.equalToSuperview()
            make.trailing.equalTo(deleteButton.snp.leading).offset(-AppMetrics.s15)
        }
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onDelete = nil
    }

    func show(_ row: QueueViewModel.Row) {
        titleLabel.text = row.title
        titleLabel.textColor = row.isCurrent ? AppColor.accent : AppColor.overlayTextSecondary
        playingBars.isHidden = !row.isCurrent
        playingBars.setPlaying(row.isPlaying)
        let leading = row.isCurrent
            ? AppMetrics.s15 + AppMetrics.queuePlayingIndicatorSide + AppMetrics.s10
            : AppMetrics.s15
        titleLeading?.update(offset: leading)
    }

    @objc private func deleteTapped() {
        onDelete?()
    }
}
