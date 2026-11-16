import Foundation

/// 取色那条链上流动的颜色 —— **sRGB，三个通道 0~1，不带透明度**。
///
/// 🔴 **为什么不直接用 `UIColor`**：取色和配渐变都是**算出来**的颜色，不是设计稿上挑的色 ——
/// 用值类型算，测试里能**精确**比数（`UIColor` 的相等要看色彩空间），整条链也不用认识 UIKit。
/// 只在最后上屏那一下由 `NowPlayingBackgroundView` 换成 `CGColor`。
///
/// 色相 / 饱和度 / 亮度用的是 **HSB（= HSV）**，跟 `UIColor.getHue(_:saturation:brightness:alpha:)`
/// 同一套定义 —— 配方的加深、提饱和，以及色不够三个时转色相补槽，都在这套坐标里做。
struct PaletteColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 从 HSB 建。`hue` 绕圈（超出 0~1 自动折回），另外两个夹在 0~1。
    init(hue: Double, saturation: Double, brightness: Double) {
        let h = Self.wrapped(hue) * 6
        let s = min(max(saturation, 0), 1)
        let v = min(max(brightness, 0), 1)
        let chroma = v * s
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - chroma

        let rgb: (red: Double, green: Double, blue: Double)
        switch Int(h) {
        case 0: rgb = (chroma, x, 0)
        case 1: rgb = (x, chroma, 0)
        case 2: rgb = (0, chroma, x)
        case 3: rgb = (0, x, chroma)
        case 4: rgb = (x, 0, chroma)
        default: rgb = (chroma, 0, x)
        }
        self.init(red: rgb.red + m, green: rgb.green + m, blue: rgb.blue + m)
    }

    /// 这个色的 HSB。灰色（三通道相等）的色相按 0 给。
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let brightest = max(red, green, blue)
        let delta = brightest - min(red, green, blue)
        let saturation = brightest > 0 ? delta / brightest : 0
        guard delta > 0 else { return (0, saturation, brightest) }

        let sector: Double
        if brightest == red {
            sector = (green - blue) / delta
        } else if brightest == green {
            sector = (blue - red) / delta + 2
        } else {
            sector = (red - green) / delta + 4
        }
        return (Self.wrapped(sector / 6), saturation, brightest)
    }

    /// 色相转 `delta`（一圈 = 1），饱和度和亮度不动。
    func shiftingHue(by delta: Double) -> PaletteColor {
        let current = hsb
        return PaletteColor(hue: current.hue + delta, saturation: current.saturation, brightness: current.brightness)
    }

    /// 三个通道差都不到 `tolerance`，就算是"接近"的同一个色。
    ///
    /// ⚠️ **故意不给默认值**：多近算"同一个色"是**调用方**的判断，不是颜色本身的性质。
    /// 曾默认 `0.15` —— 那正好和桶容差撞成一个数，看着像"复用"，其实是两件事。
    func isClose(to other: PaletteColor, tolerance: Double) -> Bool {
        abs(red - other.red) < tolerance
            && abs(green - other.green) < tolerance
            && abs(blue - other.blue) < tolerance
    }

    /// 把色相折回 0..<1。
    private static func wrapped(_ hue: Double) -> Double {
        let remainder = hue.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }
}
