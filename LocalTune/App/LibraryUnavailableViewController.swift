import SnapKit
import UIKit

/// 曲库打不开时顶上来的那一页。
///
/// 🔴 **它是为了防止「启动失败变成白屏」**：白屏上用户什么也做不了、也不知道出了什么事，
/// 只会以为 App 坏了。这一页把三件事说清 —— 哪里坏了、为什么、能怎么办 —— 再留一个「重试」。
///
/// 它只扛**启动**阶段的失败（曲库还没准备好）。跑起来之后曲库再出问题，
/// 走的是 `LibraryStore.errors` 那条流，由当前页面自己提示，不需要整页顶掉。
final class LibraryUnavailableViewController: BaseViewController {

    /// 点「重试」时通知外面 —— 具体重试什么由 `SceneDelegate` 决定（重新建服务）。
    var onRetry: (() -> Void)?

    private let error: LibraryDatabaseError

    init(error: LibraryDatabaseError) {
        self.error = error
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        layoutContent()
    }

    private func layoutContent() {
        let titleLabel = UILabel()
        // 三句话都从 `LibraryDatabaseError` 拿 —— 界面不自己拼错误文案。
        titleLabel.text = error.errorDescription
        titleLabel.font = AppFont.pageTitle
        titleLabel.textColor = AppColor.title
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let messageLabel = UILabel()
        // 「为什么」和「怎么办」合成一段；哪个是空的就自动不占位。
        messageLabel.text = [error.failureReason, error.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        messageLabel.font = AppFont.pageMessage
        messageLabel.textColor = AppColor.secondaryText
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.title = "重试"
        buttonConfiguration.baseBackgroundColor = AppColor.accent
        buttonConfiguration.baseForegroundColor = AppColor.onAccent
        let retryButton = UIButton(
            configuration: buttonConfiguration,
            primaryAction: UIAction { [weak self] _ in self?.onRetry?() }
        )

        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = AppMetrics.s20
        view.addSubview(stack)

        stack.snp.makeConstraints { make in
            // 比正中略高一点 —— 和空状态同一个道理：绝对居中看着会偏低。
            make.centerY.equalToSuperview().offset(-AppMetrics.s24)
            make.leading.trailing.equalToSuperview().inset(AppMetrics.s24)
        }
    }
}
