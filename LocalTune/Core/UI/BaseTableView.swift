import UIKit

/// 列表基类 —— 列表页统一用它，别直接用 `UITableView`。
///
/// 只收「每一张列表都想要、散着写就一定会漏」的事：
///
/// 1. **往下拖就收键盘**（`keyboardDismissMode = .onDrag`）—— 搜索框弹着键盘时，
///    拖列表本身就该把键盘收掉。这是列表的通用手感，不是某一页的需求。
/// 2. **索引条被按住的信号**（`onIndexBarTouch`）—— 系统索引条只在换字母时回调，
///    手指抬起那一刻没有公开回调；想让气泡"一松手就收"，只能旁听它的触摸。详见下面。
final class BaseTableView: UITableView {

    // MARK: - 索引条旁听

    /// 系统索引条上「手指按着 / 抬起来了」。
    ///
    /// 🔴 **为什么要绕这一下**：系统索引条只在**换字母**的时候回调
    /// （`sectionForSectionIndexTitle`）—— **手指抬起那一刻没有任何公开回调**。
    /// 想让气泡"一松手就收"，就只能旁听那条索引条上的触摸；
    /// 而索引条视图没有公开入口，只能从子视图里按类名认。
    ///
    /// - Parameter isTouching: `true` = 按着 / 手上在滑；`false` = 抬起来了。
    var onIndexBarTouch: ((Bool) -> Void)?

    /// 认出来的那条索引条（弱引用 —— 它是系统的子视图，生命周期不归我们管）。
    private weak var trackedIndexBar: UIView?

    override init(frame: CGRect, style: UITableView.Style) {
        super.init(frame: frame, style: style)
        keyboardDismissMode = .onDrag
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachIndexBarTrackingIfNeeded()
    }

    /// 索引条是**懒建**的（表格要显示时系统才造它），所以第一次布局时可能还没有 ——
    /// 这里每次都试着挂一下，挂上之后就只做一次很轻的判断。
    ///
    /// ⚠️ 为什么挂上之后不再重新找：那条路要遍历一遍子视图 + 逐个数类名，
    /// 而 `layoutSubviews` 在滚动时会被频繁调用 —— 挂上之后就该是"零成本"。
    private func attachIndexBarTrackingIfNeeded() {
        if let tracked = trackedIndexBar,
           tracked.gestureRecognizers?.contains(where: { $0 is IndexBarTouchRecognizer }) == true {
            return
        }
        guard let bar = findIndexBar() else { return }

        let recognizer = IndexBarTouchRecognizer()
        recognizer.onTouch = { [weak self] isTouching in
            self?.onIndexBarTouch?(isTouching)
        }
        bar.addGestureRecognizer(recognizer)
        trackedIndexBar = bar
    }

    /// 从子视图里认出系统那条索引条。
    ///
    /// ⚠️ 只能按**类名**认 —— 它的真名叫 `UITableViewIndex`，是系统内部视图，没有公开入口。
    /// 但**不写死等号**、只要求类名里含 `Index`：Apple 从没承诺过这个名字，
    /// 哪天改个后缀，写死等号就静默失效了（不报错、气泡再也不出现）。
    private func findIndexBar() -> UIView? {
        subviews.first { NSStringFromClass(type(of: $0)).contains("Index") }
    }
}

// MARK: - 旁听器

/// 旁听索引条上的触摸：**只听，不打断**。
///
/// 🔴 为什么不用现成的 `UILongPressGestureRecognizer`：那种会"赢"掉这次触摸、
/// 和系统索引条自己的手势打架（索引条就不跟手了）。这里要的是
/// 「识别归识别，触摸照旧发给索引条」—— 所以要自己写一个，并且：
///
/// - `cancelsTouchesInView = false`：识别了也**不取消**这次触摸，索引条照样收到；
/// - `delaysTouchesBegan / Ended = false`：不给索引条的反应加延迟；
/// - 允许**同时识别**：不跟索引条自己的手势争。
///
/// 这三条缺一条，索引条的手感就会变。
private final class IndexBarTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {

    /// 按着 / 滑（`true`）还是抬起来了（`false`）。
    var onTouch: ((Bool) -> Void)?

    convenience init() {
        self.init(target: nil, action: nil)
    }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delegate = self
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        state = .began
        onTouch?(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        state = .changed
        onTouch?(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        state = .ended
        onTouch?(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        state = .cancelled
        onTouch?(false)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
