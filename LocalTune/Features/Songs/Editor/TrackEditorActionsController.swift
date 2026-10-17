import UIKit

/// 编辑页用户动作协作者：取消 / 保存 · 换封面（系统裁剪）· 点空白收键盘 · 保存失败提示。
///
/// 页面私有协作者：依赖全部 init 注入（页面只是弹警告 / 收键盘 / 弹选择器的出口），
/// 没落账的字段经由列表协作者推 VM，不回头摸页面的东西。
@MainActor
final class TrackEditorActionsController: NSObject,
    UIImagePickerControllerDelegate,
    UINavigationControllerDelegate,
    UIAdaptivePresentationControllerDelegate {

    // MARK: - 依赖

    private let viewModel: TrackEditorViewModel

    /// 收键盘、弹选择器、弹警告、关页面 —— 这一口是页面。
    private weak var page: UIViewController?

    /// 换封面弹出菜单 / 浮层的锚点（表头那颗透明按钮，归页面装配）。
    private unowned let coverButton: UIButton

    /// 没落账的字段 —— 经列表协作者补推（见 `TrackEditorListController.flushFieldsToViewModel`）。
    private unowned let listController: TrackEditorListController

    init(
        viewModel: TrackEditorViewModel,
        page: UIViewController,
        coverButton: UIButton,
        listController: TrackEditorListController
    ) {
        self.viewModel = viewModel
        self.page = page
        self.coverButton = coverButton
        self.listController = listController
    }

    // MARK: - 两颗键

    @objc func cancelTapped() {
        page?.view.endEditing(true)
        listController.flushFieldsToViewModel()
        if viewModel.hasUnsavedChanges {
            confirmDiscardChanges()
        } else {
            page?.dismiss(animated: true)
        }
    }

    @objc func saveTapped() {
        page?.view.endEditing(true)
        // 失焦时字段才推到 VM；先把当前焦点里的字灌进去再存。
        listController.flushFieldsToViewModel()
        viewModel.saveIfNeededAndDismiss()
    }

    @objc func endEditingNow() {
        page?.view.endEditing(true)
    }

    // MARK: - 换封面

    /// 选封面 —— 系统相册选取器 + 允许裁剪（选完先进系统裁剪）。
    ///
    /// ⚠️ 歌单封面用系统照片选择器是另一回事；这里用户要的是「选完能裁」的效果，那种选择器没有这一步。
    @objc func presentCoverPicker() {
        page?.view.endEditing(true)
        guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = true
        picker.delegate = self
        if let pop = picker.popoverPresentationController {
            pop.sourceView = coverButton
            pop.sourceRect = coverButton.bounds
            pop.permittedArrowDirections = []
        }
        page?.present(picker, animated: true)
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        // 优先用裁剪结果；用户没裁再退回原图。
        guard let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage) else {
            return
        }
        viewModel.applyPickedCover(image)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    // MARK: - 下拉关闭（＝取消）

    func presentationControllerShouldDismiss(
        _ presentationController: UIPresentationController
    ) -> Bool {
        listController.flushFieldsToViewModel()
        return !viewModel.hasUnsavedChanges
    }

    func presentationControllerDidAttemptToDismiss(
        _ presentationController: UIPresentationController
    ) {
        guard let page, page.canPresentOverlay else { return }
        confirmDiscardChanges()
    }

    // MARK: - 保存失败提示

    func presentSaveError(_ error: Error) {
        guard let page else { return }
        // 优先用人话：我们自己的本地化错误；引擎抛出来的英文只当兜底线索。
        let message: String
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            message = description
        } else {
            message = "没能保存这次修改，请再试一次。"
        }
        AppAlert.notice(from: page, title: "保存失败", message: message)
    }

    // MARK: - 私有

    private func confirmDiscardChanges() {
        guard let page else { return }
        SaveChangesAlert.present(
            from: page,
            title: "是否保存修改？",
            onDiscard: { [weak self] in
                self?.page?.dismiss(animated: true)
            },
            onSave: { [weak self] in
                guard let self else { return }
                self.listController.flushFieldsToViewModel()
                self.viewModel.saveIfNeededAndDismiss()
            }
        )
    }
}
