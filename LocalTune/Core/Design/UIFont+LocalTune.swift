import UIKit

extension UIFont {

    /// 字号相对设计值最多能涨多少。
    ///
    /// 播放器是固定版式，字号不能无上限地跟着系统文字大小涨 —— 涨过头会把布局撑破。
    /// 所以上限锁在「设计值 + 3」。
    private static let maximumGrowth: CGFloat = 3

    /// 跟随系统文字大小缩放，**只放大不缩小，最多放大 3pt**。
    ///
    /// 为什么不直接用 `UIFontMetrics.scaledFont(for:maximumPointSize:)`：
    /// 它只给上限，没有下限 —— 系统文字调小时字号会被一起调小。
    /// 这里先取缩放后的值，再把区间夹到 `[设计值, 设计值 + 3]`。
    ///
    /// ⚠️ 缩放值是在**创建字体那一刻**取到的。想让已经显示出来的标签跟着系统设置实时变，
    /// 标签要打开 `adjustsFontForContentSizeCategory`。
    static func scaled(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let scaledSize = UIFontMetrics(forTextStyle: .body).scaledValue(for: size)
        let clampedSize = min(max(scaledSize, size), size + maximumGrowth)
        return UIFont.systemFont(ofSize: clampedSize, weight: weight)
    }
}
