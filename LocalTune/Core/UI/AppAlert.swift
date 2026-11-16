import UIKit

/// 弹窗的**机械骨架** —— 组框、挂键、呈现，全工程只有这一份。
///
/// ## 原则
///
/// 🔴 **「怎么说」是场景的事，留在场景；「怎么组、怎么挂、怎么 present」是机械，只此一份。**
/// 场景级文案出处（`SaveChangesAlert` / `LibraryTrackDeleteConfirmation` / `PlaylistCoverMessaging`…）
/// 照旧各管各的文案，只是**底下都走这一份**。
///
/// ⚠️ **判据不进这儿**：`prompt` 的确认键亮不亮由调用方给 `isValid`（如 `canRename`）——
/// 本类型不做任何业务判断，只管「每敲一下重算一遍」的接线。
enum AppAlert {

    /// 一个键 —— 标题、样式、点了干什么。
    struct Action {

        let title: String
        let style: UIAlertAction.Style
        let handler: (() -> Void)?

        init(_ title: String, style: UIAlertAction.Style = .default, handler: (() -> Void)? = nil) {
            self.title = title
            self.style = style
            self.handler = handler
        }

        /// 取消键的便捷写法（样式恒 `.cancel`、无动作）。
        static func cancel(_ title: String = "取消") -> Action {
            Action(title, style: .cancel)
        }
    }

    // MARK: - 底座

    /// 组一个 `.alert`，**不呈现** —— 键按传入顺序挂，`cancel` 永远在最后。
    ///
    /// ⚠️ 有几个页面「取消」习惯摆在**前面**（如歌词编辑页）—— 键序是产品决定，
    /// 想保持就把取消写成 `actions` 的一员、`cancel` 传 `nil`。
    static func make(
        title: String?,
        message: String? = nil,
        actions: [Action],
        cancel: Action? = Action.cancel()
    ) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        for action in actions {
            alert.addAction(UIAlertAction(title: action.title, style: action.style) { _ in
                action.handler?()
            })
        }
        if let cancel {
            alert.addAction(UIAlertAction(title: cancel.title, style: cancel.style))
        }
        return alert
    }

    /// 组好并呈现 —— 确认类弹窗的常用口。
    static func present(
        from host: UIViewController,
        title: String?,
        message: String? = nil,
        actions: [Action],
        cancel: Action? = Action.cancel()
    ) {
        let alert = make(title: title, message: message, actions: actions, cancel: cancel)
        host.present(alert, animated: true)
    }

    // MARK: - 薄封装 ① · 单键提示

    /// 单键提示（默认「好」）—— 「保存失败」「无法生成封面」这一类。
    static func notice(
        from host: UIViewController,
        title: String?,
        message: String? = nil,
        buttonTitle: String = "好"
    ) {
        present(from: host, title: title, message: message, actions: [Action(buttonTitle)], cancel: nil)
    }

    // MARK: - 薄封装 ② · 带一个文本框的输入弹窗

    /// 带一个文本框的输入弹窗 —— 确认键把框里的字交出来。
    ///
    /// 🔴 **「确认键亮不亮」由 `isValid` 现场判**：给了就**先算一次**（预填的原文本来就可能是空的）
    /// ＋ 每敲一下重算一遍；`nil` ＝ 恒可按。判据本身在调用方（如 `canRename`），
    /// 这里只管**接线** —— 接线只有这一份（判据唯一出处的规矩不破）。
    ///
    /// - Parameters:
    ///   - initialText: 预填文本（改名那条路喂原来的名字；新建那条路喂 `nil`）。
    ///   - returnKeyType / autocorrectionType: `nil` ＝ 不动系统默认 —— 输入框细节的直通口
    ///     （均衡器「保存自定义」在用：回车叫「完成」、关自动纠正）。
    ///   - interfaceStyle: `nil` ＝ 跟系统。`.dark` 时整框套深色、输入框键盘跟着暗 ——
    ///     给常暗页面用（均衡器页），弹系统白框刺眼。
    static func prompt(
        from host: UIViewController,
        title: String?,
        message: String? = nil,
        placeholder: String? = nil,
        initialText: String? = nil,
        keyboardType: UIKeyboardType = .default,
        clearButtonMode: UITextField.ViewMode = .whileEditing,
        returnKeyType: UIReturnKeyType? = nil,
        autocorrectionType: UITextAutocorrectionType? = nil,
        confirmTitle: String,
        isValid: ((String) -> Bool)? = nil,
        onConfirm: @escaping (String) -> Void,
        cancelTitle: String = "取消",
        interfaceStyle: UIUserInterfaceStyle? = nil
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)

        let confirm = UIAlertAction(title: confirmTitle, style: .default) { [weak alert] _ in
            let text = alert?.textFields?.first?.text ?? ""
            onConfirm(text)
        }
        // 一开始就先算一次：预填的名字本来就有可能是空的，光靠下面那条「边敲边算」盖不住。
        confirm.isEnabled = isValid?(initialText ?? "") ?? true

        alert.addTextField { textField in
            textField.placeholder = placeholder
            textField.text = initialText
            textField.keyboardType = keyboardType
            textField.clearButtonMode = clearButtonMode
            if let returnKeyType {
                textField.returnKeyType = returnKeyType
            }
            if let autocorrectionType {
                textField.autocorrectionType = autocorrectionType
            }
            if interfaceStyle == .dark {
                textField.keyboardAppearance = .dark
            }
            // 每敲一下都重算 —— 那个键要在**输字的过程中**跟着亮/灭，不是等提交。
            textField.addAction(UIAction { [weak confirm, weak textField] _ in
                guard let isValid else { return }
                confirm?.isEnabled = isValid(textField?.text ?? "")
            }, for: .editingChanged)
        }

        alert.addAction(confirm)
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel))
        if let interfaceStyle {
            alert.overrideUserInterfaceStyle = interfaceStyle
        }
        host.present(alert, animated: true)
    }
}
