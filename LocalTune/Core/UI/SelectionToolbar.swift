import UIKit

/// 多选工具条头两项 ——「全选 / 取消全选」的工厂（曲库 / 歌单详情同款）。
///
/// 后面的动作键各页不同（添加到播放列表 / 从播放列表中删除 / 删除），**不归**这儿 ——
/// 那是场景的事。见 `docs/设计/消重复设计.md` §3.4。
enum SelectionToolbar {

    /// 头两项，按顺序：全选、取消全选。
    ///
    /// ⚠️ 动作接的是 selector（`target/action`）—— 这两个键是常驻键，不需要闭包捕获。
    static func makeSelectAllItems(
        target: AnyObject?,
        selectAll: Selector,
        deselectAll: Selector
    ) -> (selectAll: UIBarButtonItem, deselectAll: UIBarButtonItem) {
        (
            UIBarButtonItem(title: "全选", style: .plain, target: target, action: selectAll),
            UIBarButtonItem(title: "取消全选", style: .plain, target: target, action: deselectAll)
        )
    }
}
