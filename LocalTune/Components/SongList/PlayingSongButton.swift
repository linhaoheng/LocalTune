import SnapKit
import UIKit

/// 列表页右下角「定位当前曲」悬浮钮 —— **可拖动、不吸附**；点一下滚到正在播那首。
///
/// 34×34、`target` 图标。
/// 🔴 它**只画 + 拖**：有没有当前曲、多选要不要藏，全是外面的事（见 `PlayingSongLocator`）。
final class PlayingSongButton: UIButton {

    /// 点一下（没拖过）—— 页面接到后滚到当前曲。
    var onTap: (() -> Void)?

    private enum Metrics {
        static let side: CGFloat = 34
        static let cornerRadius: CGFloat = 17
        /// 默认贴安全区右下的内边距。
        static let defaultInset: CGFloat = 15
        /// 拖动时相对安全区再留的边。
        static let dragPadding: CGFloat = 10
        /// 拖动判定：位移超过这点才算拖过（避免手指轻颤误伤点击）。
        static let dragThreshold: CGFloat = 4
        /// 顶部再多留一截，别压到导航栏 / 搜索框。
        static let dragTopExtra: CGFloat = 56
    }

    /// 对外：装上去时用同一套边长。
    static var side: CGFloat { Metrics.side }
    static var defaultInset: CGFloat { Metrics.defaultInset }

    private var didDrag = false
    private var usesConstraints = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AppColor.accent.withAlphaComponent(0.1)
        tintColor = AppColor.accent.withAlphaComponent(0.8)
        layer.cornerRadius = Metrics.cornerRadius
        clipsToBounds = true
        setImage(UIImage(systemName: "target"), for: .normal)
        isHidden = true
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan)))
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        didDrag = false
        super.touchesBegan(touches, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 拖过一次后约束拆了、改用 frame；转屏 / 安全区变时再夹回可视范围。
        if !usesConstraints, let superview {
            clamp(in: superview)
        }
    }

    // MARK: - 动作

    @objc private func handleTap() {
        if didDrag { return }
        onTap?()
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let superview else { return }
        if pan.state == .began {
            didDrag = false
            if usesConstraints {
                let current = frame
                snp.removeConstraints()
                translatesAutoresizingMaskIntoConstraints = true
                frame = current
                usesConstraints = false
            }
        }
        let translation = pan.translation(in: superview)
        if hypot(translation.x, translation.y) > Metrics.dragThreshold {
            didDrag = true
        }
        center = CGPoint(x: center.x + translation.x, y: center.y + translation.y)
        pan.setTranslation(.zero, in: superview)
        clamp(in: superview)
    }

    /// 夹在安全区里 —— **别写死底边 150**：迷你条高度会变，安全区才是活的。
    private func clamp(in superview: UIView) {
        let size = bounds.size
        let inset = superview.safeAreaInsets
        let pad = Metrics.dragPadding
        let minX = inset.left + pad + size.width / 2
        let maxX = superview.bounds.width - inset.right - pad - size.width / 2
        let minY = inset.top + pad + Metrics.dragTopExtra + size.height / 2
        let maxY = superview.bounds.height - inset.bottom - pad - size.height / 2
        center = CGPoint(
            x: min(max(center.x, minX), max(minX, maxX)),
            y: min(max(center.y, minY), max(minY, maxY))
        )
    }
}
