import UIKit

/// 歌单手挑封面 —— 相册选取 + **系统裁剪**（`allowsEditing`）。
///
/// 🔴 **为什么它住 `Components/`**：
/// 实测它被**两个页面**共用 —— `PlaylistsViewController.changeCover`（列表页行尾菜单）
/// 和 `PlaylistDetailViewController.changeCover`（详情页）。一个两页都在用的零件放在
/// `Features/Playlists/` 里，等于让歌单这个功能**私有**了它 —— 别的功能要用就得跨目录去找。
///
/// ⚠️ **它不碰库、不跳转**：只负责「弹系统相册 → 拿到一张图 → 回调给调用方」。
/// 存盘是 `Data/Artwork/PlaylistCoverService` 的事；页面之间的跳转才归 `AppRouter`，
/// 系统相册是**系统模态**、不进导航栈（那 28 处 alert / 分享 / picker 同理，都不算「页面跳转」）。
///
/// ⚠️ 用 `UIImagePickerController` 而不是 PHPicker：用户要「选完能裁」；
/// PHPicker 没有裁剪这一步（编辑歌曲信息页同一条理由）。
///
/// 🔴 **不要第二份状态**：别把 `coverPickerPlaylistID` 挂在 VC 上
///（`PlaylistsViewController.swift:35`）。这里用会话对象**自己带着**歌单 id，
/// 关掉就释放 —— 没有第二份。
///
/// ⚠️ **不许沉默**：相册不可用 / 选完没图 → 走 `onFailed`，由页面变成人话。
final class PlaylistCoverPickerSession: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    /// 选图失败的两种 —— 页面据此弹不同的话。
    enum Failure {
        /// 系统说相册源不可用。
        case libraryUnavailable
        /// 选完了但拿不到图（极少见）。
        case emptyImage
    }

    private let playlistID: Playlist.ID
    private let onPicked: (Playlist.ID, UIImage) -> Void
    private let onFailed: (Failure) -> Void

    /// 持有自己，避免 picker 还在屏幕上时被释放（delegate 是 weak）。
    private var retainSelf: PlaylistCoverPickerSession?

    private init(
        playlistID: Playlist.ID,
        onPicked: @escaping (Playlist.ID, UIImage) -> Void,
        onFailed: @escaping (Failure) -> Void
    ) {
        self.playlistID = playlistID
        self.onPicked = onPicked
        self.onFailed = onFailed
    }

    /// 弹出相册选一张图，选完进系统裁剪。
    static func present(
        from host: UIViewController,
        playlistID: Playlist.ID,
        onPicked: @escaping (Playlist.ID, UIImage) -> Void,
        onFailed: @escaping (Failure) -> Void
    ) {
        guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else {
            onFailed(.libraryUnavailable)
            return
        }

        let session = PlaylistCoverPickerSession(
            playlistID: playlistID,
            onPicked: onPicked,
            onFailed: onFailed
        )
        session.retainSelf = session

        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = true
        picker.delegate = session
        if let pop = picker.popoverPresentationController {
            pop.sourceView = host.view
            pop.sourceRect = CGRect(
                x: host.view.bounds.midX,
                y: host.view.bounds.midY,
                width: 1,
                height: 1
            )
            pop.permittedArrowDirections = []
        }
        host.present(picker, animated: true)
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        defer { retainSelf = nil }
        // 优先用裁剪结果；用户没裁再退回原图。
        guard let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage) else {
            onFailed(.emptyImage)
            return
        }
        onPicked(playlistID, image)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        retainSelf = nil
    }
}

/// 歌单封面相关、列表页和详情页**共用**的那几句人话 —— 只此一处。
enum PlaylistCoverMessaging {

    /// 选图失败 → HUD。
    static func showPickFailure(_ failure: PlaylistCoverPickerSession.Failure) {
        switch failure {
        case .libraryUnavailable:
            HUD.showMessage("打不开相册")
        case .emptyImage:
            HUD.showMessage("没拿到这张图")
        }
    }

    /// 生成封面失败（没源图）→ 那句 alert。
    static func presentNoSourceArtwork(from host: UIViewController) {
        AppAlert.notice(
            from: host,
            title: "无法生成封面",
            message: "这个歌单里还没有带封面的歌曲。"
        )
    }
}
