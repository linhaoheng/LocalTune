import SnapKit
import UIKit

/// 索引条按下时**屏幕正中**冒出来的那个方块 —— 里面是当前字母。
///
/// 效果：**钉在页面正中**（不是跟着手指走），60 见方、圆角 5，
/// 底色 `AppColor.badge`、字母 `AppColor.secondaryText`。
///
/// ⚠️ **不塞进系统的私有索引条视图**里（那要按类名 `UITableViewIndex` 找到它、
/// 再把窗口中心换算过去）。改成挂在**页面自己的视图**上：观感一样，
/// 但不去猜系统的内部结构，也不往系统视图里插自己的子视图。
final class IndexBubble: UIView {

    // MARK: - 常量

    private enum Constants {

        /// 方块边长。
        static let size: CGFloat = 60

        /// 圆角。
        static let cornerRadius: CGFloat = 5

        /// **兜底**：这么久还没人来收它，就自己收掉。
        ///
        /// 🔴 正常路径是**手指一松就收**（由 `BaseTableView.onIndexBarTouch` 驱动，
        /// 那边旁听了系统索引条上的触摸）。这一条只防"旁听没挂上"——
        /// 索引条视图只能按类名认，万一认不出来，气泡也不能赖在屏幕上不走。
        static let fallbackHideDelay: TimeInterval = 3
    }

    // MARK: - 零件

    private let letterLabel = UILabel()

    /// 到点收气泡的那件活儿 —— 每次显示都取消重排。
    private var pendingHide: DispatchWorkItem?

    // MARK: - 建立

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Constants.size, height: Constants.size))

        backgroundColor = AppColor.badge
        layer.cornerRadius = Constants.cornerRadius
        layer.masksToBounds = true
        isHidden = true
        // 它压在页面正中 —— 别把底下的触摸吃掉（放在这儿纯粹是给人看的）。
        isUserInteractionEnabled = false

        letterLabel.font = AppFont.indexBubbleLetter
        letterLabel.textColor = AppColor.secondaryText
        letterLabel.textAlignment = .center
        addSubview(letterLabel)
        letterLabel.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 显示 / 收起

    /// 显示这个字母。
    ///
    /// ⚠️ 居中是**每次显示都重算**的 —— 页面转屏、分屏之后中心会变，
    /// 只在加进去那次算一次的话就偏了。
    func show(_ text: String) {
        guard let host = superview else {
            assertionFailure("气泡得先被加进某个视图（页面在 layout 里加），否则没东西可居中")
            return
        }
        center = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        letterLabel.text = text
        isHidden = false
        scheduleFallbackHide()
    }

    /// 收起来。
    ///
    /// ⚠️ **手指一松开就该调这个**（`BaseTableView.onIndexBarTouch` 那条线接过来）；
    /// 它自己那个兜底定时器只是防"那条线没接上"。
    func hide() {
        pendingHide?.cancel()
        pendingHide = nil
        isHidden = true
    }

    /// 排一个"兜底收掉"的活儿 —— 期间又换了字母就重排（所以一直按着时它不会消失）。
    private func scheduleFallbackHide() {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.fallbackHideDelay, execute: work)
    }
}
