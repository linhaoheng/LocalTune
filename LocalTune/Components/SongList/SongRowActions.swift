import UIKit

/// 行尾「更多」里的一组动作 —— 页面给，行负责把它画成菜单。
///
/// 🔴 **文案不能写在行里**：行不认识"这一页是曲库还是歌单"，也就不知道主操作该叫
/// 「删除」还是别的。把它交给页面；行只负责**拼装**和**长相**。
struct SongRowActions {

    /// 编辑歌曲信息。
    let onEdit: () -> Void

    /// 下一首播放。
    let onPlayNext: () -> Void

    /// 添加到播放列表。
    let onAddToPlaylist: () -> Void

    /// 喜爱 / 取消喜爱。`nil` = 菜单不画这一项（歌单详情页不要它）。
    let favorite: (isFavorite: Bool, toggle: () -> Void)?

    /// 共享。参数是触发它的那个按钮（iPad 上分享面板是 popover，要指向它）。
    let onShare: (UIView) -> Void

    /// 主操作（曲库页 / 详情页菜单文案都是「删除」；详情点下去是移出歌单）。
    let mainAction: SongRowAction
}

/// 行尾「更多」里的一项操作内容。
struct SongRowAction {
    let title: String
    let systemImage: String
    let isDestructive: Bool
    let handler: () -> Void
}

/// 行尾那一格**画什么** —— 两种可能，一次说全。
enum SongRowAccessory {

    /// 一组「更多」操作 —— 点它弹菜单。
    case menu(SongRowActions)

    /// 一枚勾选标记 —— **要的那首歌在不在手上这一份里**。
    case selection(isSelected: Bool)

    /// 行尾什么都不画 —— 手动排序时拖柄占右边，别跟「更多」抢位。
    case none
}
