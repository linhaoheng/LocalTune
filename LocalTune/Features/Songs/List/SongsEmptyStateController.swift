import SnapKit
import UIKit

/// 曲库页**空状态协作者** —— 空库时那块占位：一句话 + 一个「导入歌曲」按钮。
///
/// 形状和文案都在 `EmptyStateView` 身上，这里只回答两件事：
/// **什么时候摆出来**、**点了之后干什么**。
@MainActor
final class SongsEmptyStateController {

    // MARK: - 依赖

    /// 占位叠在页面正中（`view.addSubview`）—— 出口是页面。
    private unowned let page: SongsViewController

    /// 点了走「打开文件」那条路 —— 和加号菜单里那一项**同一个入口**，不另做一套导入。
    private unowned let importController: SongsImportController

    /// 曲库一首歌都没有时，摆在页面中间那块占位。
    ///
    /// ⚠️ **是可选、不是惰性属性**：库里有歌的话它一辈子不会被建出来 ——
    /// 惰性属性一旦被读就会建，而这里"判断要不要显示"本身就要读它。
    private var emptyStateView: EmptyStateView?

    init(page: SongsViewController, importController: SongsImportController) {
        self.page = page
        self.importController = importController
    }

    // MARK: - 显 / 收

    /// 曲库一首歌都没有，就把那块占位摆上；有歌就收掉。
    ///
    /// 🔴 判断的是「**曲库**里没有歌」，**不是**"当前列表是空的"：
    /// 搜没搜到的时候列表也是空的，可那会儿摆一句「您的音乐库中没有歌曲」是**假话** ——
    /// 库里明明有歌，只是没搜着。那种时候弹一句「未找到相关歌曲」就够了
    /// （见页面 `bindSearchFeedback`）。
    ///
    /// ⚠️ 这块占位是**叠在表格上面**的（`view.addSubview`），不是替换掉表格 ——
    /// 它是透明的、只占中间一条，底下的表格照旧在。
    func updateEmptyState(_ snapshot: SongsViewModel.Snapshot) {
        guard snapshot.rows.isEmpty, !snapshot.isSearching else {
            emptyStateView?.removeFromSuperview()
            return
        }
        // 已经在屏幕上了就别再摆一遍 —— 每来一次快照都会走到这儿。
        guard emptyStateView?.superview == nil else { return }

        let stateView = emptyStateView ?? makeEmptyStateView()
        emptyStateView = stateView
        page.view.addSubview(stateView)
        // 左右贴满、竖直居中 —— 页面正中那一块。
        stateView.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.trailing.equalToSuperview()
        }
    }

    // MARK: - 私有

    private func makeEmptyStateView() -> EmptyStateView {
        let stateView = EmptyStateView(
            message: "您的音乐库中没有歌曲",
            actionTitle: "导入歌曲"
        )
        // 点了走「打开文件」那条路 —— 和加号菜单里那一项**同一个入口**，不另做一套导入。
        stateView.onAction = { [weak importController] in
            importController?.presentFilePicker()
        }
        return stateView
    }
}
