import UIKit

/// 播放页封面的左右拖切 —— **只碰两层的 transform / alpha**，不取图、不解比例。
///
/// 封面框怎么解、图画哪一张，仍是 `CoverArtworkSlot` 的事。
/// 这里只回答：手指这一下该预览哪一侧、松手切不切、切的话两层怎么滑走。
///
/// 松手口令复用 `horizontalSwipeCommit` / `horizontalSwipeAction`
/// （迷你条同一套；封面自己的阈值在 `AppMetrics.nowPlayingCoverSwipe*`）。
///
/// ## 线程
///
/// **只在主线程**：手势回调、动画 completion 都在主线程；`isCommitting` 不需要锁。
///
/// 🔴 **别照**`CoverView` 那一套：
/// - `cancelled` 当 `ended` 会误切歌；
/// - 速度 OR 位移、不问同号，会切到预览反面；
/// - `PlayManager.shared.adjacentTrack` 看不到插队。
final class NowPlayingCoverSwipe: NSObject, UIGestureRecognizerDelegate {

    /// 提交切歌动画进行中 —— 这段时间封面 `show` 不改当前图。
    private(set) var isCommitting = false

    /// 这一侧有没有可切的邻居。真相来自 peek，不在这里查队列。
    var hasPrevious = false
    var hasNext = false

    /// 过死区换方向、或提交前重填预览。`true` ＝ 上一首。
    var onPreviewDirection: ((Bool) -> Void)?

    /// 滑出动画走完。`true` ＝ 上一首。
    var onCommitted: ((Bool) -> Void)?

    private weak var host: UIView?
    private weak var currentLayer: UIView?
    private weak var previewLayer: UIView?

    private enum Direction {
        case previous
        case next
        case none
    }

    private var direction: Direction = .none
    private var initialX: CGFloat = 0

    /// 手势挂在封面盒子上，位移作用在当前 / 预览两层。
    func attach(host: UIView, current: UIView, preview: UIView) {
        self.host = host
        self.currentLayer = current
        self.previewLayer = preview
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        host.addGestureRecognizer(pan)
    }

    /// 只认水平拖 —— 竖直留给 PanModal 往下拖走。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let host else {
            return true
        }
        let velocity = pan.velocity(in: host)
        return abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let host, let currentLayer, !isCommitting else { return }
        let width = host.bounds.width
        guard width > 0 else { return }

        switch gesture.state {
        case .began:
            initialX = currentLayer.transform.tx
            direction = .none

        case .changed:
            var offset = gesture.translation(in: host).x + initialX
            offset = min(max(offset, -width), width)
            let nextDirection: Direction = offset > 0 ? .previous : .next
            if direction != nextDirection,
               abs(offset) > AppMetrics.nowPlayingCoverSwipeDirectionDeadZone {
                direction = nextDirection
                onPreviewDirection?(nextDirection == .previous)
            }
            applyTransforms(offset: offset, width: width)

        case .ended:
            finishPan(
                translationX: currentLayer.transform.tx,
                velocityX: gesture.velocity(in: host).x,
                width: width
            )

        case .cancelled:
            // 系统取消 ≠ 用户松手提交。
            springBack(width: width)

        default:
            break
        }
    }

    private func finishPan(translationX: CGFloat, velocityX: CGFloat, width: CGFloat) {
        let commit = horizontalSwipeCommit(
            translationX: translationX,
            velocityX: velocityX,
            commitDistance: AppMetrics.nowPlayingCoverSwipeCommitDistance,
            commitVelocity: AppMetrics.nowPlayingCoverSwipeCommitVelocity
        )
        let action = horizontalSwipeAction(
            commit: commit,
            hasPrevious: hasPrevious,
            hasNext: hasNext
        )
        switch action {
        case .playPrevious:
            commitSwipe(toPrevious: true, width: width)
        case .playNext:
            commitSwipe(toPrevious: false, width: width)
        case .springBack:
            springBack(width: width)
        }
    }

    private func applyTransforms(offset: CGFloat, width: CGFloat) {
        currentLayer?.transform = CGAffineTransform(translationX: offset, y: 0)
        let previewBase = offset <= 0 ? width : -width
        previewLayer?.transform = CGAffineTransform(translationX: offset + previewBase, y: 0)

        let progress = min(abs(offset) / width, 1)
        currentLayer?.alpha = 1 - progress * AppMetrics.nowPlayingCoverSwipeCurrentFadeFactor
        previewLayer?.alpha = min(progress * AppMetrics.nowPlayingCoverSwipePreviewRiseFactor, 1)
    }

    private func commitSwipe(toPrevious: Bool, width: CGFloat) {
        isCommitting = true
        // 按提交方向重填 —— 不能沿用滑动过程中最后一次预览（迷你条同一条）。
        onPreviewDirection?(toPrevious)
        let exitX = toPrevious ? width : -width
        UIView.animate(
            withDuration: AppMetrics.nowPlayingCoverSwipeCommitDuration,
            delay: 0,
            options: .beginFromCurrentState,
            animations: { [weak self] in
                self?.currentLayer?.transform = CGAffineTransform(translationX: exitX, y: 0)
                self?.currentLayer?.alpha = 0
                self?.previewLayer?.transform = .identity
                self?.previewLayer?.alpha = 1
            },
            completion: { [weak self] _ in
                guard let self else { return }
                self.onCommitted?(toPrevious)
                self.resetVisuals()
                self.isCommitting = false
            }
        )
    }

    private func springBack(width: CGFloat) {
        let previewExit: CGFloat = direction == .previous ? -width : width
        UIView.animate(
            withDuration: AppMetrics.nowPlayingCoverSwipeSpringDuration,
            delay: 0,
            usingSpringWithDamping: AppMetrics.nowPlayingCoverSwipeSpringDamping,
            initialSpringVelocity: AppMetrics.nowPlayingCoverSwipeSpringVelocity,
            options: [],
            animations: { [weak self] in
                self?.currentLayer?.transform = .identity
                self?.currentLayer?.alpha = 1
                self?.previewLayer?.transform = CGAffineTransform(translationX: previewExit, y: 0)
                self?.previewLayer?.alpha = 0
            },
            completion: { [weak self] _ in
                self?.direction = .none
            }
        )
    }

    private func resetVisuals() {
        currentLayer?.transform = .identity
        currentLayer?.alpha = 1
        previewLayer?.transform = .identity
        previewLayer?.alpha = 0
        direction = .none
        initialX = 0
    }
}
