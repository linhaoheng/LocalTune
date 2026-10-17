import SnapKit
import UIKit

/// 空状态占位 —— **一行说明 + 一个行动按钮**，没有图标。
///
/// **不做图片**：空页面加一张图只是让它"热闹一点"，不解决用户此刻的问题
/// （"这里为什么是空的、我该做什么"）—— 一句话 + 一个按钮正好回答这两件事。
///
/// 🔴 **文案由调用方给**（`message` / `actionTitle`），组件自己一句话都不含：
/// 写死在这儿的话，第二个场景就得复制一份出来，那份拷贝迟早和这份走散。
///
/// ⚠️ **高度不写死**，由内容撑（说明 + 间距 + 按钮）：系统文字调大时这句说明会变高，
/// 固定高度会把字裁掉。
final class EmptyStateView: UIView {

    /// 说明文字和按钮之间留多少。
    private static let messageToAction: CGFloat = AppMetrics.s12

    /// 点那个按钮要做什么。**由调用方接** —— 组件不知道"导入"是什么。
    var onAction: (() -> Void)?

    private let messageLabel = UILabel()

    /// 按钮的长相和手感都在它自己身上（见 `PressScaleActionButton`），这儿只负责接线。
    private let actionButton = PressScaleActionButton()

    init(message: String, actionTitle: String) {
        super.init(frame: .zero)

        messageLabel.text = message
        messageLabel.textAlignment = .center
        // 允许换行：系统文字调到最大时这句话可能一行放不下。
        messageLabel.numberOfLines = 0
        messageLabel.font = AppFont.emptyStateMessage
        messageLabel.textColor = AppColor.title
        addSubview(messageLabel)

        actionButton.title = actionTitle
        actionButton.addTarget(self, action: #selector(handleAction), for: .touchUpInside)
        addSubview(actionButton)

        // 说明文字钉上面和左右；按钮钉底下，中间那条缝就是它俩的距离。
        // ⇒ 整个块的高度 = 说明 + 缝 + 按钮，**由内容撑出来**（见类注释）。
        messageLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
        }
        actionButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview()
            make.top.equalTo(messageLabel.snp.bottom).offset(Self.messageToAction)
        }
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    @objc private func handleAction() {
        onAction?()
    }
}
