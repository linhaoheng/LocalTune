import SnapKit
import UIKit

/// 两页共用的「定位当前曲」悬浮钮**宿主** —— 装钮、显隐、滚动停了再藏。
///
/// 曲库页和歌单详情页行为一样，所以这一份躺在 `Components/SongList/`，
/// 页面只负责：有没有当前曲、是不是多选、点了滚到哪一行。
///
/// ## 显隐规则（把常见毛病改掉）
///
/// | 条件 | 行为 |
/// |---|---|
/// | 没有当前曲 / 多选挡住 | **立刻藏**，取消待办隐藏 |
/// | 用户开始滚列表 | 若可用则**露出来** |
/// | 列表停稳后 6 秒 | 再藏（列表还在拖 / 还在减速则不藏） |
///
/// 🔴 **不把计时器当状态**：
/// 「能不能露」是 `isAvailable`；「此刻露不露」是按钮的 `isHidden`；
/// 延迟隐藏只是一条可取消的待办，跟多选 / 有没有歌**分开判**。
///
/// 🔴 也不学 `updatePlayingSongButton` **只藏不露**：换歌本身不自动弹出 ——
/// 要等用户滚一下才露；没歌 / 多选才立刻藏。
final class PlayingSongLocator {

    private enum Metrics {
        static let hideDelay: TimeInterval = 6
    }

    private let button = PlayingSongButton()
    private weak var hostView: UIView?
    private weak var tableView: UITableView?
    private var hideWork: DispatchWorkItem?
    private var isAvailable = false

    /// 装到页面上，默认藏在安全区右下。
    ///
    /// - `hostView`：页面根视图（钮加在它上面，盖住表格）。
    /// - `tableView`：用来问「还在拖 / 还在减速吗」。
    /// - `onLocate`：点钮 → 滚到当前曲。
    func install(on hostView: UIView, tableView: UITableView, onLocate: @escaping () -> Void) {
        self.hostView = hostView
        self.tableView = tableView
        button.onTap = onLocate
        hostView.addSubview(button)
        button.snp.makeConstraints { make in
            make.width.height.equalTo(PlayingSongButton.side)
            make.trailing.equalTo(hostView.safeAreaLayoutGuide).offset(-PlayingSongButton.defaultInset)
            make.bottom.equalTo(hostView.safeAreaLayoutGuide).offset(-PlayingSongButton.defaultInset)
        }
    }

    /// 「能不能露」—— 有当前曲且不被多选挡住。
    ///
    /// ⚠️ 变 `false` **立刻藏**；变 `true` **不自动弹**（等用户滚列表，见 `userBeganScrolling`）。
    func setAvailable(_ available: Bool) {
        isAvailable = available
        if !available {
            cancelHide()
            button.isHidden = true
        }
    }

    /// 用户开始拖列表 —— 可用就露出来，并取消待办隐藏。
    func userBeganScrolling() {
        guard isAvailable else { return }
        cancelHide()
        button.isHidden = false
        hostView?.bringSubviewToFront(button)
    }

    /// 列表停稳（拖结束且不减速，或减速结束）—— 安排 6 秒后藏。
    func scrollDidSettle() {
        guard isAvailable else { return }
        scheduleHide()
    }

    // MARK: - 私有

    private func scheduleHide() {
        cancelHide()
        let work = DispatchWorkItem { [weak self] in
            self?.hideIfIdle()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.hideDelay, execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    private func hideIfIdle() {
        hideWork = nil
        guard isAvailable else {
            button.isHidden = true
            return
        }
        // 还在拖 / 还在减速 ⇒ 别藏，等下一次真正停稳。
        if tableView?.isDragging == true || tableView?.isDecelerating == true { return }
        button.isHidden = true
    }
}
