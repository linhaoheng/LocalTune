import SVProgressHUD
import UIKit

/// 全 App 的浮层 —— **薄薄一层壳，里面是 SVProgressHUD**。
///
/// 为什么各处**不直接调** SVProgressHUD、要包这一层：
///
/// - **换库只动这一个文件**（这个文件今天就换过一次：先是自己写的，现在换成库）；
/// - 皮肤（暗色材质、白字、圆角、字号、最短停留）在**一处**配，全局统一；
/// - 调用方只认识 `HUD.showProgress / showMessage / hide`，底下用谁它们不用知道。
///
/// 效果配置照映射表 §3 的浮层要求：
///
/// - **进度态拦截触摸**（`maskType = .clear`）—— 正在导入时不该让人乱点；
/// - **提示态不拦截**（`.none`），过几秒自己消失；
/// - 暗色材质模糊、白字、圆角、字号、最短停留时间 —— 数值全走令牌（`AppMetrics` / `AppFont`）。
///
/// ⚠️ 这里是**界面层的全局**：同一时刻全 App 只有一块浮层。跟服务层单例不是一回事 ——
/// 状态全在 SVProgressHUD 自己手里（它本来就是按全局单件设计的），这里只负责
/// 「调它之前把皮肤配好」和「把调用意图翻译成它的接口」。
enum HUD {

    /// 提示的语气 —— 决定用库里的哪种图标（成功 ✓ / 出错 ✕ / 信息 ⓘ）。
    enum Style {
        case success
        case error
        case info
    }

    // MARK: - 对外

    /// 显示（或**原地更新**）进度浮层。
    ///
    /// 有分母走**确定进度环**；还没数出总数（`discovering` 阶段）走转圈 —— 库自己会画。
    /// 反复调是安全的：进度和文字就是原地换，不会叠出第二块。
    static func showProgress(_ progress: ImportProgress) {
        configureSkin()
        // 进度态**锁 UI**（透明遮罩拦触摸）—— 正在导入时不该让人乱点。
        SVProgressHUD.setDefaultMaskType(.clear)

        if let fraction = progress.fraction {
            SVProgressHUD.showProgress(Float(fraction), status: progress.hudMessage)
        } else {
            SVProgressHUD.show(withStatus: progress.hudMessage)
        }
    }

    /// 提示浮层：几秒后自己消失，**不拦截触摸**。
    ///
    /// - Parameters:
    ///   - text: 主文案（一句话结果）
    ///   - detail: 统计那行（可空）
    ///   - note: 第三行小字（第一条失败的原因，可空）
    ///
    /// 三段合成一条多行文字交给库 —— 它的状态标签支持多行
    /// （源码 `SVProgressHUD.m:1308`：`_statusLabel.numberOfLines = 0`）。
    static func showMessage(
        _ text: String,
        detail: String? = nil,
        note: String? = nil,
        style: Style = .info
    ) {
        configureSkin()
        // 提示态**不拦**：点在浮层外照常穿透到下面的界面。
        SVProgressHUD.setDefaultMaskType(.none)

        let status = [text, detail, note].compactMap { $0 }.joined(separator: "\n")
        switch style {
        case .success: SVProgressHUD.showSuccess(withStatus: status)
        case .error:   SVProgressHUD.showError(withStatus: status)
        case .info:    SVProgressHUD.showInfo(withStatus: status)
        }
    }

    /// 收起（并恢复「默认不拦」）。
    ///
    /// ⚠️ 导入那条路**不调它** —— 跑完是把进度换成结果提示，提示自己会消失。
    static func hide() {
        SVProgressHUD.dismiss()
        SVProgressHUD.setDefaultMaskType(.none)
    }

    // MARK: - 皮肤

    /// 皮肤设置。**每次显示前都调一遍** —— 它只是把同一组常数赋给库的全局设置，
    /// 反复赋无害；好处是连「配过没有」这个状态都不用存，少一个能出错的地方。
    private static func configureSkin() {
        SVProgressHUD.setDefaultStyle(.custom)
        SVProgressHUD.setHudViewCustomBlurEffect(UIBlurEffect(style: .systemMaterialDark))
        SVProgressHUD.setBackgroundColor(.clear)
        SVProgressHUD.setForegroundColor(AppColor.overlayText)
        SVProgressHUD.setFont(AppFont.hudMessage)
        SVProgressHUD.setCornerRadius(AppMetrics.hudCornerRadius)
        SVProgressHUD.setMinimumSize(AppMetrics.hudMinimumSize)
        SVProgressHUD.setDefaultAnimationType(.flat)
        SVProgressHUD.setMinimumDismissTimeInterval(AppMetrics.hudMinimumDismissInterval)
        SVProgressHUD.setDefaultMaskType(.none)
    }
}
