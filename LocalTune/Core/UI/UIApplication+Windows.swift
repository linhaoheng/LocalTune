import UIKit

/// 「当前有哪些窗口」—— **全工程只有这一个答案**。
///
/// ⚠️ 为什么不能各写各的：场景化（iOS 13）之后，窗口归**场景**管，取窗口这条路只剩
/// 「遍历场景再取每个场景的窗口」这一条。散着写就会各漏各的。
///
/// ⚠️ 那两个老 API **别用**：
/// - `UIApplication.keyWindow` —— iOS 13 起废弃，场景化之后**一直返回 nil**；
/// - `UIApplicationDelegate.window` —— 更老，而且声明成**可选**的，
///   谁去调它、谁没实现，就是 `unrecognized selector` 直接崩。
///   老库还在写这两个（见 `AppDelegate.window` 上的说明），我们这边只认这一处。
extension UIApplication {

    /// 当前所有窗口（可能不止一个：键盘、系统浮层各占一个）。
    var appWindows: [UIWindow] {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
    }

    /// 当下那个 key window —— 「现在用户在看哪一块」。
    var keyAppWindow: UIWindow? {
        appWindows.first { $0.isKeyWindow }
    }
}
