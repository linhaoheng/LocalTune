import SwiftUI
import UIKit

/// 把 SwiftUI 的歌词海报面板接进 UIKit 的页面世界。
///
/// ## 为什么要有这一层壳
///
/// 项目其余部分是纯 UIKit —— 跳转只有 `AppRouter` 一个出口。海报面板是 SwiftUI 写的，
/// 于是需要一个"壳"，`UIHostingController` 本身就是。这里只把**只有 UIKit 做得了**的两件事接上：
/// 关掉这一页、弹系统分享面板（iPad 上那个气泡要锚点）。
///
/// ## 依赖怎么进去
///
/// 状态机（`LyricsPosterComposer`）由 `AppRouter` 造好递进来 —— 面板不认识曲库、
/// 也不认识播放器，跟其余页面一个口径。
@MainActor
final class LyricsPosterHostingController: UIHostingController<LyricsPosterShareSheet> {

    init(composer: LyricsPosterComposer) {
        super.init(rootView: LyricsPosterShareSheet(composer: composer))
        // 两个动作在装好之后补上：它们要 `self`，而 `self` 得等 `super.init` 之后才可用。
        rootView.onDismiss = { [weak self] in self?.closePage() }
        rootView.onShare = { [weak self] url in self?.shareFile(at: url) }
    }

    required init?(coder: NSCoder) {
        // 本页只由 `init(composer:)` 构造 —— 从 nib / storyboard 反序列化是写错了。
        // 调试期当场停下报出来；正式版返回 nil（不崩，也不带着半成品状态继续跑）。
        assertionFailure("LyricsPosterHostingController 只由代码构造，不该走 init(coder:)")
        return nil
    }

    /// 收起这一页 —— **连同盖在它上面的**（系统分享面板）一起收。
    ///
    /// 🔴 不能直接 `dismiss(animated:)`：上面还盖着一层时，UIKit 只收**上面那一层**。
    /// 让弹出它的那一页来收，才是"它和它上面的全部"（同 `NowPlayingViewController.closePage`）。
    private func closePage() {
        (presentingViewController ?? self).dismiss(animated: true)
    }

    /// 分享导出的 PNG。
    ///
    /// 传**文件 URL** 而不是 `UIImage`：接收方拿到的是原始 PNG，不会被转码成缩略图。
    ///
    /// ⚠️ 锚点：分享键在底部那一条上，所以取**底部中间那一小格**，不用整块 `view`。
    private func shareFile(at url: URL) {
        presentShareSheet(
            [url],
            anchoredTo: view,
            sourceRect: CGRect(
                x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1
            )
        )
    }
}
