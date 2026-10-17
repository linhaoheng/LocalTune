import UIKit

extension UIViewController {

    /// 这一层上面**还能不能再盖一层东西** —— 弹任何东西之前都问它。
    ///
    /// 🔴 **判据只此一处**：`presentedViewController == nil`。
    /// 它原来在 13 个地方各写了一遍（`AppRouter` 11 ＋ 两个 `ActionsController`），
    /// 而「第 14 个地方忘了写」的后果是**点了没反应** —— 用户以为 App 卡了，事后查不出来。
    /// 收成一个有名字的判据之后，至少「什么算盖着」只有一个答案。
    ///
    /// 🔴 **光有这个判据还不够**：真正让调用点漏不掉的是**出口** ——
    /// `AppRouter` 那两条弹页面的路（`presentAsSheet` / `presentPanModal`）把门闩装在自己身上，
    /// 调用方连写都不用写。这个属性是给**不经过路由**的那两处（页面自己弹确认框）用的。
    ///
    /// ⚠️ 它只管「能不能弹」，**不管弹什么**：sheet / PanModal / alert 是三条路，
    /// 各自的形态差得远，硬合成一个函数只会让参数长成一排开关。
    var canPresentOverlay: Bool { presentedViewController == nil }
}
