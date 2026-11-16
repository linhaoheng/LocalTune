import Foundation

/// 一张海报上歌词排下来的字号与高度（单位是画布点，也就是导出像素 —— 海报按 `scale = 1` 渲染）。
struct LyricsPosterTypeMetrics: Hashable {
    let lyricFontSize: Double
    /// 两句之间的间距。同一句内折行的间距更紧，长句子才读得出是一个意思。
    let lyricLineSpacing: Double
    let titleFontSize: Double
    let captionFontSize: Double
    /// 扣掉风格两侧留白之后，文字真正能用的宽度。
    let textWidth: Double
    /// 按这套字号估出来的歌词块总高。
    let estimatedHeight: Double
    /// 连最小字号 ＋ 最紧行距都放不下。海报会被裁着导出去，所以界面必须提醒用户
    /// 换更高的画幅或少选几句，而不是悄悄交出一张缺了半句的图。
    let overflows: Bool
}

/// 给歌词挑一个"铺满又不溢出"的字号。
///
/// 🔴 这里**不能用 SwiftUI 的 `minimumScaleFactor`**：海报是固定画布的离屏渲染
/// （`ImageRenderer`），放不下的内容是被**裁掉**而不是被缩小。所以字号必须**事先解出来**。
enum LyricsPosterLayoutPolicy {

    /// 风格默认给文字留的画布宽度比例。
    static let defaultTextWidthRatio: Double = 0.80
    /// 风格默认允许歌词块占的画布高度比例。剩下的留给标题、艺人、封面和署名。
    static let defaultLyricHeightRatio: Double = 0.54
    static let defaultLineSpacingFactor: Double = 0.42

    /// 一行文字实际占的高度倍数。取得比系统行高略保守 ——
    /// 估小了歌词会在离屏渲染时被裁掉，而离屏渲染没有"挤一挤"的机会。
    private static let lineHeightFactor: Double = 1.45
    private static let sizeStep: Double = 1
    /// 行距按这个顺序收紧。宁可句挨句紧一点，也好过把字缩到看不清。
    private static let lineSpacingFactors: [Double] = [0.42, 0.30, 0.22]

    static func metrics(
        for content: LyricsPosterContent,
        canvas: LyricsPosterCanvas,
        textWidthRatio: Double = defaultTextWidthRatio,
        lyricHeightRatio: Double = defaultLyricHeightRatio
    ) -> LyricsPosterTypeMetrics {
        let width = canvas.pixelWidth
        let textWidth = width * textWidthRatio
        let availableHeight = canvas.pixelHeight * lyricHeightRatio
        let maximumSize = width * 0.085
        // 下限定得低是有意的：八句长词配方形画幅时，25 点单行排版比 32 点每句折两行更省高度、也更好读。
        let minimumSize = width * 0.022

        // 短的一段允许排大；长的一开始就小一点，搜索不用每次都走满整个区间。
        let startingSize = min(maximumSize, maximumSize * startingScale(for: content))
        // 每行的宽度只跟文字有关，先量一次，后面几百轮试算就只剩算术了。
        let widths = lineWidths(of: content)

        func build(size: Double, spacingFactor: Double, height: Double, overflows: Bool)
            -> LyricsPosterTypeMetrics {
            LyricsPosterTypeMetrics(
                lyricFontSize: size,
                lyricLineSpacing: size * spacingFactor,
                titleFontSize: width * 0.040,
                captionFontSize: width * 0.026,
                textWidth: textWidth,
                estimatedHeight: height,
                overflows: overflows
            )
        }

        // 候选字号从大到小，末尾一定带上下限本身：按固定步长递减会跨过下限，
        // 于是"最小字号都放不下"这个判断其实从没试过最小字号。
        var candidates: [Double] = []
        var size = startingSize
        while size > minimumSize {
            candidates.append(size)
            size -= sizeStep
        }
        candidates.append(minimumSize)

        for spacingFactor in lineSpacingFactors {
            for size in candidates {
                let height = blockHeight(
                    widths: widths,
                    lyricFontSize: size,
                    textWidth: textWidth,
                    lineSpacingFactor: spacingFactor
                )
                if height <= availableHeight {
                    return build(size: size, spacingFactor: spacingFactor, height: height, overflows: false)
                }
            }
        }

        // 连最小字号 ＋ 最紧行距都放不下。仍然给一套能渲染的尺寸（总得画出点东西），
        // 但把 overflows 立起来交给界面去提示。
        let tightest = lineSpacingFactors[lineSpacingFactors.count - 1]
        let height = blockHeight(
            widths: widths,
            lyricFontSize: minimumSize,
            textWidth: textWidth,
            lineSpacingFactor: tightest
        )
        return build(size: minimumSize, spacingFactor: tightest, height: height, overflows: true)
    }

    /// 每行的 em 宽度。字号变化不影响它，所以只量一次。
    private static func lineWidths(of content: LyricsPosterContent) -> [Double] {
        content.lines.map { estimatedEmWidth(of: $0.text) }
    }

    private static func blockHeight(
        widths: [Double],
        lyricFontSize: Double,
        textWidth: Double,
        lineSpacingFactor: Double
    ) -> Double {
        guard !widths.isEmpty, lyricFontSize > 0, textWidth > 0 else { return 0 }
        var total = 0.0
        for width in widths {
            let rows = rowCount(emWidth: width, fontSize: lyricFontSize, textWidth: textWidth)
            total += Double(rows) * lyricFontSize * lineHeightFactor
        }
        total += lyricFontSize * lineSpacingFactor * Double(max(widths.count - 1, 0))
        return total
    }

    private static func rowCount(emWidth: Double, fontSize: Double, textWidth: Double) -> Int {
        let capacity = textWidth / fontSize
        guard capacity > 0 else { return 1 }
        return max(1, Int(ceil(emWidth / capacity)))
    }

    /// `text` 的宽度，单位 em，按标量估。
    ///
    /// 海报排版只需要知道"一行会折一次还是三次"，而在一个跟平台无关的策略里
    /// 拿不到真正的文本量度。
    static func estimatedEmWidth(of text: String) -> Double {
        text.unicodeScalars.reduce(0) { total, scalar in total + emWidth(of: scalar) }
    }

    private static func emWidth(of scalar: Unicode.Scalar) -> Double {
        let value = scalar.value
        switch value {
        case 0x20, 0x09:
            return 0.28
        case 0x21...0x40, 0x5B...0x60, 0x7B...0x7E:
            // ASCII 标点与数字。
            return value >= 0x30 && value <= 0x39 ? 0.55 : 0.34
        case 0x41...0x5A:
            return 0.66
        case 0x61...0x7A:
            return 0.52
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x20000...0x2FFFD, 0x30000...0x3FFFD:
            // 全角 CJK 与谚文。
            return 1.0
        case 0x3000...0x303F:
            return 1.0
        case 0x1F300...0x1FAFF, 0x2600...0x27BF:
            return 1.1
        default:
            return 0.58
        }
    }

    /// 段落越长，字号搜索从越低处起步 —— 循环因此更短，结果也随长度单调。
    private static func startingScale(for content: LyricsPosterContent) -> Double {
        switch content.lines.count {
        case 0, 1: return 1.0
        case 2: return 0.92
        case 3: return 0.84
        case 4: return 0.76
        case 5, 6: return 0.68
        default: return 0.60
        }
    }
}
