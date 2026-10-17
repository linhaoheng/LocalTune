import UIKit

extension UIViewController {

    /// 弹系统分享面板 —— **全工程唯一出处**。
    ///
    /// 🔴 **为什么挂在 `UIViewController` 上、不挂 `BaseViewController`**：分享不是"某一页"的职责，
    /// 是「系统弹窗」这个能力。挂基类的话，继承不到 `BaseViewController` 的那几种就各写一份 ——
    /// 原来正是这样长出 4 份的（`UIHostingController` 一份、两个 ActionsController 各一份，
    /// 而基类那份反而**一个调用点都没有**）。
    ///
    /// ⚠️ **它不是页面之间的跳转** —— 所以不走 `AppRouter`（路由管的是"去哪一页"）。
    ///
    /// - Parameters:
    ///   - items: 分享什么（`URL` / 文本 / 图片都行）。
    ///     ⚠️ 传**文件 URL** 而不是 `UIImage`：接收方拿到的是原始文件，不会被转码成缩略图。
    ///   - sourceView: **锚点视图**。iPad 上分享面板是气泡，**不给锚点会直接崩**。
    ///     默认取**它自己的 `bounds`** —— 所以直接把触发分享的那个按钮传进来就行，
    ///     不用自己做坐标转换（`sourceRect` 本来就活在 `sourceView` 自己的坐标系里）。
    ///   - sourceRect: 只有锚点不是那个视图的整块时才显式给
    ///     （例：歌词海报页的分享键在底部那一条上，锚点取底部中间那一小格）。
    func presentShareSheet(
        _ items: [Any],
        anchoredTo sourceView: UIView,
        sourceRect: CGRect? = nil
    ) {
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceRect ?? sourceView.bounds
        }
        present(sheet, animated: true)
    }
}
