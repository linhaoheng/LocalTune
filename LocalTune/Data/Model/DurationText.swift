import Foundation

/// 「秒数 → 给人看的时长文字」—— **全工程唯一一处**。
///
/// 🔴 **为什么要单独一个类型**：同一条规则原本只有列表行用（`Track.durationText`），
/// 播放页那两个时间标签是第二个用它的地方。抄一份的话，两边迟早会走散 ——
/// 而走散的表现是"同一首歌在列表里写 3:15、在播放页写 3:16"，这种错没人会当场发现。
///
/// ⚠️ 它**不依赖任何界面框架**（不 `import UIKit`），所以能躺在 `Data/Model/` 里、
/// 让列表（Data）和播放页（Features）都用它。
enum DurationText {

    /// 不到一小时写 `分:秒`（分钟补零，`03:05`），满一小时写 `时:分:秒`
    /// （小时不补零，`1:05:07`）。
    ///
    /// 秒数**由调用方先四舍五入到整数**再传进来：毫秒那份要的是"四舍五入到秒，
    /// 不是截断"（`119_600 ms` 该显示 `02:00`，截断会少报一秒），
    /// 播放进度那份也一样 —— 一条规则，两处不各判一次。
    ///
    /// - Parameter seconds: **非负**的秒数。`0` 是合法的（进度条开头就是 0），
    ///   负数只可能是调用方算错了 —— 那种情况按"程序员写错"处理，不悄悄夹成 0
    ///   （夹一下就把 bug 藏了）。
    static func text(seconds: Int) -> String {
        guard seconds >= 0 else {
            assertionFailure("时长是负数 —— 调用方算错了（进度 / 时长都只可能是非负的）")
            return "00:00"
        }
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        let remainder = seconds % 60
        guard hours > 0 else { return String(format: "%02d:%02d", minutes, remainder) }
        return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }
}
