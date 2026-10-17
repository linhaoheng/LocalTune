import Foundation

/// 「往后走该走到哪一格」—— **纯函数**：只吃「现在是第几格、一共几格、什么模式」，吐「下一格是第几格」。
enum PlayNext {

    /// 往后一格。`nil` ＝ 到头了（顺序 / 随机自动播完走到最后一首）。
    static func nextIndex(current: Int, count: Int, mode: PlaybackMode) -> Int? {
        guard count > 0, current >= 0, current < count else { return nil }

        switch mode {
        case .sequential, .shuffle:
            return current + 1 < count ? current + 1 : nil
        case .all:
            return (current + 1) % count
        case .one:
            return current
        }
    }

    /// 往前一格。`nil` ＝ 到头了（顺序 / 随机 / 单曲已经停在第一首）。
    static func previousIndex(current: Int, count: Int, mode: PlaybackMode) -> Int? {
        guard count > 0, current >= 0, current < count else { return nil }

        switch mode {
        case .sequential, .one, .shuffle:
            return current > 0 ? current - 1 : nil
        case .all:
            return current > 0 ? current - 1 : count - 1
        }
    }

    /// 用户点「上一首 / 下一首」用的走法：**一律回绕**（同列表循环）。
    ///
    /// 「顺序 / 随机到头停」只约束**自动播完**，不约束用户明确按键。
    static let userSkipMode: PlaybackMode = .all

    /// 删当前曲之后接「紧挨的下一首」：**顺序推进、不回绕**。
    ///
    /// ⚠️ 不用 `userSkipMode`（会回绕到第一首——那不是「下一首」）；
    /// 也不用当前 `playbackMode`：`.one` 会粘在上一首，`.all` 会回绕。
    /// 队尾没有下一首 ⇒ `nil` ⇒ 调用方停播并 idle。
    static let afterRemovalMode: PlaybackMode = .sequential
}
