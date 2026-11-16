import UIKit

/// 「是否保存…」两键确认 —— 编辑页 / 挑歌页共用。
///
/// 文案由调用方给标题；键固定为左「不保存」、右「保存」，**无副标题**。
/// 机械骨架（组框 / 挂键 / present）走 `AppAlert`（唯一出处）。
enum SaveChangesAlert {

    /// - Parameters:
    ///   - title: 例如「是否保存修改？」「是否保存添加？」
    ///   - onDiscard: 点「不保存」
    ///   - onSave: 点「保存」
    static func present(
        from host: UIViewController,
        title: String,
        onDiscard: @escaping () -> Void,
        onSave: @escaping () -> Void
    ) {
        AppAlert.present(
            from: host,
            title: title,
            actions: [
                AppAlert.Action("不保存") { onDiscard() },
                AppAlert.Action("保存", style: .destructive) { onSave() },
            ],
            cancel: nil
        )
    }
}
