import Foundation

/// 导入 / 扫描的进度 —— **跑的过程中**浮层要用的那一份快照。
///
/// ⚠️ **只有两个阶段**：两条流程都是「先数一遍 → 再逐个处理」，中间没有能分开报的阶段，
/// 硬拆只会让文案乱闪。所以 `Phase` 只留这两个真实存在的。
///
/// `fraction` 要有**分母**：动手前先数出总数，再报「处理到第几个 / 共几个」。
///
/// ⚠️ **这里只放「跑的时候真的会显示」的数。**
/// 跑的过程中顶上那行只报「已导入 n 首」，所以只有 `imported` 是从 `ImportResult` 抄来的快照；
/// 「已在库 / 重复跳过 / 失败」三个数**跑的时候不显示**，它们只属于**结束那一屏** ——
/// 那一屏直接读 `ImportResult`，**不从这儿抄**。
/// （早先这里也照抄过那三个字段；但谁都没读，而且每次循环都要手工同步一遍，所以删了。）
struct ImportProgress: Equatable, Sendable {

    enum Phase: Equatable, Sendable {
        /// 还在数「这一趟要处理多少份」。这时候还没有分母。
        case discovering
        /// 正在逐个处理。
        case processing
    }

    var phase: Phase = .discovering

    /// 正在处理的那一份的文件名。**回调要排在处理之前发** ——
    /// 排在后面的话，浮层上写的永远是"上一首"，正在处理的那首反而看不见。
    var currentFileName = ""

    var processed = 0
    var total = 0

    /// 跑的过程中顶上那行报的就是它 —— `ImportResult.imported` 的快照。
    var imported = 0

    /// 处理到几分之几。还没有总数（`discovering`）时返回 `nil`，界面画不确定进度。
    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(processed) / Double(total)))
    }
}
