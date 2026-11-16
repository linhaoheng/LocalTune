import UIKit

/// 换主题 —— 把**外观档位**（`AppTheme`）设到所有窗口上。
///
/// - ✅ **管**：窗口算浅色还是深色；换的时候可以**渐变**过去。
/// - ❌ **不管导航栏长什么样** —— 那是**跟着「一条栈」走**的，归 `AppNavigationController`
/// 这儿只管**窗口**这一档。
enum AppAppearance {

    /// 把外观档位应用到**所有窗口**。
    ///
    /// 颜色一行都不用改：`AppColor` 那一层是动态色，系统按窗口的外观自己去取
    /// 浅色或深色那一份（见 `ColorRadix.swift` 的 `uiColor`）——
    /// 这里只要告诉窗口「现在算哪种外观」。
    ///
    /// ⚠️ 窗口**刚建出来、还没显示**时调也有效（窗口一建出来就在它的场景里了）——
    /// 启动时要在 `makeKeyAndVisible()` 之前调，否则会先闪一下默认外观。
    /// 那种场合**不要**开渐变（还没显示，没什么可溶解的）。
    ///
    /// - Parameters:
    ///   - theme: 要切到的那一档。
    ///   - animated: 要不要**渐变**过去。系统换 `overrideUserInterfaceStyle` 是**瞬间**的 ——
    ///     要渐变，得自己拍一张**旧样子**盖在窗口上，换完外观再让这张图淡出。
    ///   - completion: 淡出**结束**后调（调用方拿它收尾，比如把按钮解锁）。
    static func applyTheme(
        _ theme: AppTheme,
        animated: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        let windows = UIApplication.shared.appWindows
        let style = theme.interfaceStyle

        guard animated, !windows.isEmpty else {
            windows.forEach { $0.overrideUserInterfaceStyle = style }
            completion?()
            return
        }

        // 🔴 **别用 `UIView.transition(with: window, ...)`** —— 那样**导航栏和页面会各化各的**
        // （实机看到的就是两块分开在变）。
        //
        // 做法：先给窗口拍一张**整屏旧样子**盖上去 → 换外观 → 让这张图淡出。
        // 快照是一整张图，淡出就是**整屏一起**，不会有缝。
        let snapshots = windows.compactMap { window -> UIView? in
            guard let snapshot = window.snapshotView(afterScreenUpdates: false) else { return nil }
            snapshot.frame = window.bounds
            snapshot.isUserInteractionEnabled = false
            window.addSubview(snapshot)
            return snapshot
        }

        windows.forEach { $0.overrideUserInterfaceStyle = style }

        guard !snapshots.isEmpty else {
            completion?()
            return
        }

        for (index, snapshot) in snapshots.enumerated() {
            UIView.animate(
                withDuration: themeTransitionDuration,
                delay: 0,
                // ⚠️ 带上 `allowUserInteraction`：不带的话，这段时间里整个界面点不动。
                options: [.curveEaseInOut, .allowUserInteraction]
            ) {
                snapshot.alpha = 0
            } completion: { _ in
                snapshot.removeFromSuperview()
                // 所有窗口同时开始、时长也一样 —— 最后一个的完成就是全部完成。
                if index == snapshots.count - 1 { completion?() }
            }
        }
    }

    /// 换外观时那次溶解的时长。
    ///
    /// 出处：StoryPad（Flutter）抽屉里的主题按钮 —— 那边同样是「先让颜色渐变过去，
    /// 图标随后才换」。这一档是为了让颜色变化**看得出来**、又不拖沓。
    ///
    /// ⚠️ 图标的换图动画**不等它走完**（那样慢半拍）—— 那头的延迟是独立的，不跟这个数走。
    private static let themeTransitionDuration: TimeInterval = 0.25
}
