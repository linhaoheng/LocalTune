import Foundation

/// 播放页背景**那条渐变的两头** —— 由主色按压暗配方算出来。
///
/// 🔴 **纯函数**：主色进、端色出，能单测。视图（`NowPlayingBackgroundView`）只管把它画上去。
///
/// 配方 = **屏幕上看得见的那一条**（右上 → 左下）：
///
/// ```
/// 起点：第三个主色加深 0.20
/// 终点：第一个主色先加深 0.15 → 提饱和 0.15 → 再加深 0.05
/// ```
///
/// ⚠️ 还存在另一种写法（第一 → 第二个主色），但那一层被这一条整块盖住、从没上过屏 ——
/// 只写看得见的。第二个主色不进这条可见渐变。
struct BackdropGradient: Equatable {
    let start: PaletteColor
    let end: PaletteColor

    /// 没封面时的样子 —— 和有封面时**同一套配方**，只是原料换成兜底那三个色。
    static let fallback = BackdropGradient(palette: .fallback)

    init(palette: ArtworkPalette) {
        start = Self.deepened(palette.tertiary, by: Recipe.tertiaryDim)
        let primaryDimmed = Self.deepened(palette.primary, by: Recipe.primaryDim)
        end = Self.deepened(Self.saturated(primaryDimmed, by: Recipe.endSaturate), by: Recipe.endDim)
    }
}

private extension BackdropGradient {

    ///
    /// ⚠️ 留在配方旁边、不进令牌层：它们是"怎么从主色推出端色"的参数，不是哪个界面元素的颜色。
    enum Recipe {
        /// 终点链第一步：第一个主色压暗多少。
        static let primaryDim = 0.15
        /// 起点：第三个主色压暗多少（亮度乘 `1 − 它`）。
        static let tertiaryDim = 0.20
        /// 终点：对已压暗的第一个主色提 `endSaturate` 饱和、再压暗 `endDim`。
        static let endSaturate = 0.15
        static let endDim = 0.05
        /// 每次加深都顺手把饱和度乘这么多（封顶 1）。
        static let deepenSaturationBoost = 1.15
    }

    /// **加深**：亮度乘 `1 − amount`，饱和度乘 1.15（封顶 1）。
    ///
    /// ⚠️ 这一步叫 `darken`（压暗），可它**同时提了饱和** —— 名字只说了一半。
    /// 叫"加深"是因为两件事一起做，颜色才是"更深更浓"，而不是"更暗更灰"。
    static func deepened(_ color: PaletteColor, by amount: Double) -> PaletteColor {
        let hsb = color.hsb
        return PaletteColor(
            hue: hsb.hue,
            saturation: min(hsb.saturation * Recipe.deepenSaturationBoost, 1),
            brightness: (1 - amount) * hsb.brightness
        )
    }

    /// 饱和度**加**上 `amount`（封顶 1），色相和亮度不动。
    static func saturated(_ color: PaletteColor, by amount: Double) -> PaletteColor {
        let hsb = color.hsb
        return PaletteColor(hue: hsb.hue, saturation: min(hsb.saturation + amount, 1), brightness: hsb.brightness)
    }
}
