import Foundation

/// 跳进度的合法秒数。锁屏给的时间没有滑杆量程，判断只能在这儿做一次。
///
/// 非有限 → 不当 seek。有时长就夹进 `0...duration`；时长还不知道（`0` / 非有限）只保证 ≥ 0。
/// 续播那条 3 秒门槛不在这儿。
func clampedSeekPosition(requested: TimeInterval, duration: TimeInterval) -> TimeInterval? {
    guard requested.isFinite else { return nil }
    let lower = max(0, requested)
    guard duration.isFinite, duration > 0 else { return lower }
    return min(lower, duration)
}
