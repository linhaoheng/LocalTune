import UIKit

/// 曲库**单首**删除确认 —— 文案与三键的唯一出处。
///
/// 曲库行尾、播放页「更多 → 删除」共用；禁止两处手写漂移
///
/// ⚠️ 多选批量删除用另一套话（「这首 / 这 N 首」），不走这儿。
enum LibraryTrackDeleteConfirmation {

    /// 组好确认框；调用方 `present`。
    ///
    /// - Parameters:
    ///   - songTitle: 歌名，嵌进标题《…》。
    ///   - onDeleteLibraryOnly: 「删除」—— 只从曲库去掉。
    ///   - onDeleteWithFiles: 「同时删除文件」—— 连磁盘一起删。
    static func makeAlert(
        songTitle: String,
        onDeleteLibraryOnly: @escaping () -> Void,
        onDeleteWithFiles: @escaping () -> Void
    ) -> UIAlertController {
        AppAlert.make(
            title: "你确定要从音乐库中删除《\(songTitle)》这首歌吗？",
            actions: [
                AppAlert.Action("删除", style: .destructive) { onDeleteLibraryOnly() },
                AppAlert.Action("同时删除文件", style: .destructive) { onDeleteWithFiles() },
            ]
        )
    }
}
