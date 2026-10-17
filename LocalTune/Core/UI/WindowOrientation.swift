import UIKit

/// 窗口该听哪一页的转屏口令。
///
/// 播放页是 present 出来的，不在 Tab 的 selected 里。系统问窗口时若只听根 VC，
/// 手机永远竖屏。别按页面类型名放行 —— App 不该认识页面类型。
/// 哪一页要接管窗口方向，自己声明这个协议。
protocol ControlsWindowOrientation: UIViewController {}

enum WindowOrientation {

    /// 沿着 Tab / Nav / presented 走到顶；若链上有人声明了接管，听**最上面那个**
    /// （队列、歌词设置盖在播放页上时，底下播放页的横屏不收回去）。
    static func mask(from root: UIViewController?) -> UIInterfaceOrientationMask {
        let chain = chain(from: root)
        if let controlling = chain.reversed().first(where: { $0 is ControlsWindowOrientation }) {
            return controlling.supportedInterfaceOrientations
        }
        return chain.last?.supportedInterfaceOrientations ?? .portrait
    }

    static func chain(from root: UIViewController?) -> [UIViewController] {
        var result: [UIViewController] = []
        var current = root
        while let vc = current {
            result.append(vc)
            if let presented = vc.presentedViewController {
                current = presented
                continue
            }
            if let tab = vc as? UITabBarController {
                current = tab.selectedViewController
                continue
            }
            if let nav = vc as? UINavigationController {
                let next = nav.visibleViewController ?? nav.topViewController
                current = next === vc ? nil : next
                continue
            }
            break
        }
        return result
    }
}
