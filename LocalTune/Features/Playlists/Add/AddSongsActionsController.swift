import UIKit

/// 「添加歌曲到歌单」页**用户动作那一头** —— 左上「取消」、右上「完成」、下拉关闭的拦截。
///
/// 页面私有协作者：页面回答「这一页长什么样」，这里回答「点了之后干什么」。
/// 依赖全部 init 注入；弹警告、关页面都经由页面这个出口。
@MainActor
final class AddSongsActionsController: NSObject, UIAdaptivePresentationControllerDelegate {

    // MARK: - 依赖

    private let viewModel: AddSongsViewModel

    /// 弹「是否保存添加」、关掉自己，都得有个出口 —— 这一口就是页面。
    private weak var page: UIViewController?

    init(viewModel: AddSongsViewModel, page: UIViewController) {
        self.viewModel = viewModel
        self.page = page
    }

    // MARK: - 下拉关闭

    /// 没有改动时允许系统直接下拉关闭；有改动时拦住关闭并询问是否保存添加。
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        !viewModel.hasUnsavedChanges
    }

    /// `shouldDismiss` 拒绝后由系统通知这里，避免在判断阶段直接弹窗。
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        guard let page, page.canPresentOverlay else { return }
        confirmSaveAdditions()
    }

    // MARK: - 两颗键

    /// 左上「取消」—— 有改动先问是否保存；没改动直接关。
    ///
    /// ⚠️ 这一页从头到尾没写过库（勾选只是这一页自己的状态，见 `AddSongsViewModel`），
    /// 「不保存」关掉＝丢掉勾选；「保存」＝走「完成」同一条写库路。
    @objc func cancelTapped() {
        if viewModel.hasUnsavedChanges {
            confirmSaveAdditions()
        } else {
            page?.dismiss(animated: true)
        }
    }

    /// 右上「完成」—— **到这一刻才写库**；写成了才关页。
    ///
    /// 🔴 **失败不退页**：用户勾了半天，写库一失败就把他弹回去、还不知道为什么，
    /// 那是把活儿丢了。留在这一页、给一句人话 —— 他还能再点一次。
    @objc func doneTapped() {
        do {
            try viewModel.save()
            page?.dismiss(animated: true)
        } catch {
            HUD.showMessage("保存失败", detail: error.localizedDescription, style: .error)
        }
    }

    // MARK: - 私有

    private func confirmSaveAdditions() {
        guard let page else { return }
        SaveChangesAlert.present(
            from: page,
            title: "是否保存添加？",
            onDiscard: { [weak self] in
                self?.page?.dismiss(animated: true)
            },
            onSave: { [weak self] in
                self?.doneTapped()
            }
        )
    }
}
