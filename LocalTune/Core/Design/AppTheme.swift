import UIKit

/// App 的外观档位 —— **只有浅色和深色两档**。
///
/// 🔴 它管的是「**哪一套色值生效**」，不是具体颜色：颜色本身写在 `AppColor` /
/// `RadixPalette` 里（动态色，浅深各写了一份），这里只是那个开关 ——
/// 把档位设给窗口，系统按它去取对应那一份。
///
/// ⚠️ 默认**浅色**，不跟系统走：App 自己定，用户自己切。
enum AppTheme: String, CaseIterable, Sendable {

    case light
    case dark

    /// 这一档对应系统的哪种外观。
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }

    /// 界面上显示的名字。
    var title: String {
        switch self {
        case .light: "浅色模式"
        case .dark: "深色模式"
        }
    }

    /// 按钮上那张图 —— 画的是**现在这一档**，不是「点了会变成什么」。
    var iconName: String {
        switch self {
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
}
