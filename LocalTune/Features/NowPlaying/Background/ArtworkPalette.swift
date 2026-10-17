import UIKit

/// 现成配方要的**三个槽**。
///
/// 取色在 `CoverPalette`（票数从多到少）。这里按副本10 的配套填法：前三名进槽，
/// 不够三个就转色相补齐。配方左下吃 `primary`（第 1 色），右上吃 `tertiary`（第 3 色）；
/// `secondary`（第 2 色）屏幕上不用。
struct ArtworkPalette: Equatable {
    let primary: PaletteColor
    let secondary: PaletteColor
    let tertiary: PaletteColor

    /// 封面取不到色时用的那一份 —— 色值在 `AppColor.NowPlayingBackdrop.fallbackPalette`，**全工程只这一处**。
    static let fallback = ArtworkPalette(
        primary: PaletteColor(AppColor.NowPlayingBackdrop.fallbackPalette.primary),
        secondary: PaletteColor(AppColor.NowPlayingBackdrop.fallbackPalette.secondary),
        tertiary: PaletteColor(AppColor.NowPlayingBackdrop.fallbackPalette.tertiary)
    )

    init(primary: PaletteColor, secondary: PaletteColor, tertiary: PaletteColor) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
    }

    /// 票数前三进槽；不够三个用色相补，第三色和第一色太接近时改用第二色。
    init(cover: CoverPalette) {
        let picked = cover.swatches.prefix(3).map(\.color)
        // 取到三个色，但第三色和第一色接近，就直接用第二色当第三色
        if picked.count >= 3, picked[2].isClose(to: picked[0], tolerance: Tuning.tertiaryNearPrimary) {
            self.init(primary: picked[0], secondary: picked[1], tertiary: picked[1])
            return
        }
        switch picked.count {
        case 1:
            self.init(
                primary: picked[0],
                secondary: picked[0].shiftingHue(by: Tuning.hueShiftForSingle),
                tertiary: picked[0].shiftingHue(by: -Tuning.hueShiftForSingle)
            )
        case 2:
            self.init(
                primary: picked[0],
                secondary: picked[1],
                tertiary: picked[1].shiftingHue(by: Tuning.hueShiftForPair)
            )
        default:
            self.init(primary: picked[0], secondary: picked[1], tertiary: picked[2])
        }
    }
}

private extension ArtworkPalette {

    enum Tuning {
        /// 只取到一个色时，用 ± 这么多色相补出另外两个。
        static let hueShiftForSingle = 0.08
        /// 只取到两个色时，用第二个色 + 这么多色相补出第三个。
        static let hueShiftForPair = 0.1
        /// 第 3 色与第 1 色三个通道**都**差不到这么多 ⇒ 算"看着同一个色"，`tertiary` 改用第 2 色。
        /// ⚠️ 和 `CoverPalette` 的桶容差（0.15）**不是一回事**：那个问"进哪个桶"，这个问"像不像"。
        static let tertiaryNearPrimary = 0.23
    }
}

private extension PaletteColor {

    /// 令牌层给的是 `UIColor`（兜底那三个色）—— 换成这条链用的值。
    init(_ color: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Double(red), green: Double(green), blue: Double(blue))
    }
}
