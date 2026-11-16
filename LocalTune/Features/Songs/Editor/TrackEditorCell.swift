import SnapKit
import UIKit

/// 歌曲信息编辑页的三种行：文件信息（只读）· 字段（输入框）· 歌词（多行）。
///
/// 只画、不查数据。布局数字一律进 `AppMetrics`。
enum TrackEditorCell {

    /// 共用：右对齐标题列 + 左对齐内容列。
    private enum Layout {
        static var titleLeading: CGFloat { AppMetrics.trackEditorFieldTitleLeading }
        static var titleWidth: CGFloat { AppMetrics.trackEditorFieldTitleWidth }
        static var rowHeight: CGFloat { AppMetrics.trackEditorEstimatedRowHeight }
        static var contentLeading: CGFloat { AppMetrics.trackEditorContentLeading }
        static var contentTrailing: CGFloat { AppMetrics.trackEditorContentTrailing }
        static var fieldHeight: CGFloat { AppMetrics.trackEditorFieldHeight }
    }

    // MARK: - 文件信息

    final class Info: UITableViewCell {
        static let reuseID = "TrackEditorInfoCell"

        private let titleLabel = UILabel()
        private let valueLabel = UILabel()

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            selectionStyle = .none
            backgroundColor = .secondarySystemGroupedBackground
            titleLabel.font = AppFont.editorFieldTitle
            titleLabel.textColor = AppColor.title
            titleLabel.textAlignment = .right
            titleLabel.lineBreakMode = .byTruncatingTail
            valueLabel.font = AppFont.editorFieldValue
            valueLabel.textColor = AppColor.title
            valueLabel.textAlignment = .left
            valueLabel.lineBreakMode = .byTruncatingTail
            contentView.addSubview(titleLabel)
            contentView.addSubview(valueLabel)
            titleLabel.snp.makeConstraints { make in
                make.leading.equalToSuperview().offset(Layout.titleLeading)
                make.top.bottom.equalToSuperview()
                make.width.equalTo(Layout.titleWidth)
                make.height.equalTo(Layout.rowHeight)
            }
            valueLabel.snp.makeConstraints { make in
                make.leading.equalToSuperview().offset(Layout.contentLeading)
                make.trailing.equalToSuperview().offset(-Layout.contentTrailing)
                make.centerY.equalToSuperview()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
            return nil
        }

        func show(title: String, value: String) {
            titleLabel.text = title.hasSuffix(":") ? title : "\(title):"
            valueLabel.text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - 可编辑字段

    final class Field: UITableViewCell {
        static let reuseID = "TrackEditorFieldCell"

        private let titleLabel = UILabel()
        private weak var hostedField: UITextField?

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            selectionStyle = .none
            backgroundColor = .secondarySystemGroupedBackground
            titleLabel.font = AppFont.editorFieldTitle
            titleLabel.textColor = AppColor.title
            titleLabel.textAlignment = .right
            titleLabel.lineBreakMode = .byTruncatingTail
            contentView.addSubview(titleLabel)
            titleLabel.snp.makeConstraints { make in
                make.leading.equalToSuperview().offset(Layout.titleLeading)
                make.top.bottom.equalToSuperview()
                make.width.equalTo(Layout.titleWidth)
                make.height.equalTo(Layout.rowHeight)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
            return nil
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            hostedField?.removeFromSuperview()
            hostedField = nil
        }

        func show(title: String, field: UITextField) {
            titleLabel.text = title.hasSuffix(":") ? title : "\(title):"
            hostedField?.removeFromSuperview()
            hostedField = field
            field.font = AppFont.editorFieldValue
            field.textColor = AppColor.title
            field.textAlignment = .left
            field.clearButtonMode = .never
            field.returnKeyType = .next
            field.tintColor = AppColor.accent
            field.backgroundColor = .clear
            field.borderStyle = .roundedRect
            field.layer.borderWidth = 0
            field.layer.cornerRadius = 0
            contentView.addSubview(field)
            field.snp.remakeConstraints { make in
                make.leading.equalToSuperview().offset(Layout.contentLeading)
                make.trailing.equalToSuperview().offset(-Layout.contentTrailing)
                make.centerY.equalToSuperview()
                make.height.equalTo(Layout.fieldHeight)
            }
        }
    }

    // MARK: - 歌词

    final class Lyrics: UITableViewCell {
        static let reuseID = "TrackEditorLyricsCell"

        private let titleLabel = UILabel()
        private let chromeField = UITextField()
        private weak var hostedView: UITextView?

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)
            selectionStyle = .none
            backgroundColor = .secondarySystemGroupedBackground
            titleLabel.font = AppFont.editorFieldTitle
            titleLabel.textColor = AppColor.title
            titleLabel.textAlignment = .right
            chromeField.borderStyle = .roundedRect
            chromeField.isUserInteractionEnabled = false
            chromeField.backgroundColor = .clear
            contentView.addSubview(titleLabel)
            contentView.addSubview(chromeField)
            titleLabel.snp.makeConstraints { make in
                make.leading.equalToSuperview().offset(Layout.titleLeading)
                make.top.equalToSuperview()
                make.width.equalTo(Layout.titleWidth)
                make.height.equalTo(Layout.rowHeight)
            }
            chromeField.snp.makeConstraints { make in
                make.leading.equalToSuperview().offset(Layout.contentLeading)
                make.trailing.equalToSuperview().offset(-Layout.contentTrailing)
                make.top.equalToSuperview().offset(AppMetrics.trackEditorLyricsVerticalInset)
                make.bottom.equalToSuperview().offset(-AppMetrics.trackEditorLyricsVerticalInset)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
            return nil
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            hostedView?.removeFromSuperview()
            hostedView = nil
        }

        func show(title: String, textView: UITextView) {
            titleLabel.text = title.hasSuffix(":") ? title : "\(title):"
            hostedView?.removeFromSuperview()
            hostedView = textView
            textView.font = AppFont.editorFieldValue
            textView.textColor = AppColor.title
            textView.backgroundColor = .clear
            textView.isScrollEnabled = false
            textView.contentInset = .zero
            textView.contentInsetAdjustmentBehavior = .never
            textView.textContainerInset = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
            textView.textContainer.lineFragmentPadding = 0
            textView.tintColor = AppColor.accent
            contentView.addSubview(textView)
            textView.snp.remakeConstraints { make in
                make.edges.equalTo(chromeField).inset(UIEdgeInsets(top: 2, left: 4, bottom: 2, right: 4))
            }
        }
    }
}

/// 歌词多行输入 —— 高度跟着内容长。
final class TrackEditorGrowingTextView: UITextView {
    private var lastFittingWidth: CGFloat = 0

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : lastFittingWidth
        guard width > 1 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: AppMetrics.trackEditorFieldHeight)
        }
        let inset = textContainerInset
        textContainer.size = CGSize(
            width: max(1, width - inset.left - inset.right),
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let height = ceil(used.height + inset.top + inset.bottom)
        return CGSize(width: UIView.noIntrinsicMetric, height: max(AppMetrics.trackEditorFieldHeight, height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 1, abs(width - lastFittingWidth) > 0.5 else { return }
        lastFittingWidth = width
        invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            guard let table = self?.enclosingTableView() else { return }
            UIView.performWithoutAnimation {
                table.beginUpdates()
                table.endUpdates()
            }
        }
    }

    private func enclosingTableView() -> UITableView? {
        var node: UIView? = superview
        while let current = node {
            if let table = current as? UITableView { return table }
            node = current.superview
        }
        return nil
    }
}
