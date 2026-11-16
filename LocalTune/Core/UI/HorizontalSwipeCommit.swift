import CoreGraphics
import Foundation

/// 左右滑松手后该干什么 —— **纯手势数学**，不碰视图、不碰队列。
///
/// 迷你条和播放页封面共用这一处：位移 / 速度 → 上一首 / 下一首 / 回弹。
/// 阈值由调用方传入（迷你条 80、封面 100），这里不算业务。
///
/// 🔴 **速度和位移不许反向各自独立提交** ——
/// 轻拂必须与当前位移**同号**，否则预览方向和提交方向会打架。
enum HorizontalSwipeCommit {

    /// 提交切到上一首（手指右滑）。
    case previous

    /// 提交切到下一首（手指左滑）。
    case next

    /// 回弹，不切歌。
    case cancel
}

/// 松手时：位移 / 速度 → 上一首 / 下一首 / 回弹。
///
/// - Parameters:
///   - translationX: 松手时相对原点的水平位移（右为正 = 上一首方向）。
///   - velocityX: 松手瞬时水平速度（点/秒）。
///   - commitDistance: 位移提交阈值。
///   - commitVelocity: 速度提交阈值。
func horizontalSwipeCommit(
    translationX: CGFloat,
    velocityX: CGFloat,
    commitDistance: CGFloat,
    commitVelocity: CGFloat
) -> HorizontalSwipeCommit {
    let distancePrevious = translationX > commitDistance
    let distanceNext = translationX < -commitDistance
    // 🔴 轻拂必须与位移同号 —— 「速度 OR 位移」且不问同号的话，会提交到预览反面。
    let flickPrevious = velocityX > commitVelocity && translationX > 0
    let flickNext = velocityX < -commitVelocity && translationX < 0

    if distancePrevious || flickPrevious { return .previous }
    if distanceNext || flickNext { return .next }
    return .cancel
}

/// 手势方向 + 两侧有没有邻居 → 最终动作。
///
/// 没邻居仍回弹、**不**发切歌 —— 空队列也发 `previousTapped` 的话，用户会以为真切了。
enum HorizontalSwipeAction {
    case playPrevious
    case playNext
    case springBack
}

func horizontalSwipeAction(
    commit: HorizontalSwipeCommit,
    hasPrevious: Bool,
    hasNext: Bool
) -> HorizontalSwipeAction {
    switch commit {
    case .previous:
        return hasPrevious ? .playPrevious : .springBack
    case .next:
        return hasNext ? .playNext : .springBack
    case .cancel:
        return .springBack
    }
}
