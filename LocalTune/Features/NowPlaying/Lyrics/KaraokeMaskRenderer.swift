import UIKit

/// 逐字扫光的**排版 ＋ 掩码合成**。
///
/// ## 两件事
///
/// 1. **排版**：TextKit 算出每个词占哪几块矩形（`UILabel` 内部排版不公开）。
/// 2. **合成一张 mask**：按播放时间把**每个词自己的贡献**画进同一张图
///    （满亮＝实心白，扫到一半＝本词矩形上的柔边渐变）。
///
/// ## 🔴 为什么是「分块各画一笔、合成一张」而不是 lit + 唯一 sweep
///
/// primuse（`KaraokeLineView`）的不变量是：**每个 syllable 各自往 mask 里画一份**。
/// 我们留它，为的是**一块矩形一笔**：一行可能折成好几行、一个字也可能跨行 ⇒
/// 同一时刻"有的块已经满了、有的块才扫一半"，全行唯一的那根渐变表达不了。
///
/// ⚠️ 逐字窗口**首尾相接、不再重叠**（下限 `0.18` 已撤掉）——
/// 同一时刻通常只有一个词落在 `(0, 1)` 里。但这**不代表**能退回唯一 sweep：折行照样不行。
///
/// 旧写法（全行唯一 `CAGradientLayer`）还有另一个毛病：下一字一开扫就覆盖上一字
/// 还没落硬边的尾巴 —— 上一字白高亮掉一截。出处：primuse Canvas `isolatedProgressMask`。
///
/// ## 🔴 排版属性必须跟 cell 的 `UILabel` 逐项相同
///
/// 同 font、同段落样式（含行内行距 6）、同宽 —— 否则换行位置不同，矩形整体错位。
/// 段落样式由外面传入（`LyricsLineCell.paragraph(alignment:)`），这儿不写第二份。
///
/// ## 🔴 顶对齐，不是居中
///
/// cell 正文顶对齐 ⇒ 矩形**不需要垂直偏移**。`offsetY = max((高 − usedHeight) / 2, 0)`
/// 那种写法是**居中**，套上来会整片下移。
final class KaraokeMaskRenderer {

    /// 渲染参数 —— 跟 `KaraokeSweepPolicy.Tuning` 分开放：那层是"扫到哪"，
    /// 这层是"画成什么样"。**不进 `AppMetrics`**。
    enum Tuning {

        /// 柔边宽度（**progress 单位**，总宽）。每边摊一半。
        /// 出处：primuse `KaraokeLineView.maskEdgeWidth = 0.12`。
        static let maskEdgeWidth: CGFloat = 0.12
    }

    /// 合成 mask 时的一笔 —— **一个词可以贡献多笔**（跨行折了；或前几段实心、末段柔边）。
    enum Stroke: Equatable {
        /// 整块实心白（已唱完，或跨行词里已经扫过的那段）。
        case fill(CGRect)
        /// 本词矩形上的横向柔边；`lower`/`upper` 是 progress 单位的渐变停点（`[0, lower, upper, 1]`）。
        case soft(rect: CGRect, lower: CGFloat, upper: CGFloat)
    }

    // MARK: - 内部

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)

    private struct CacheKey: Equatable {
        let text: String
        let fontName: String
        let pointSize: CGFloat
        let lineSpacing: CGFloat
        let alignment: Int
        let width: CGFloat
    }

    private var cachedKey: CacheKey?
    private var cachedRects: [[CGRect]] = []

    init() {
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        container.size = CGSize(width: 0, height: Self.unboundedHeight)
    }

    private static let unboundedHeight: CGFloat = 100_000

    // MARK: - 排版

    /// 每个词占哪几块矩形 —— 下标跟 `segments` 一一对应。
    func rects(
        for segments: [KaraokeSweepPolicy.Segment],
        text: String,
        font: UIFont,
        paragraph: NSParagraphStyle,
        width: CGFloat
    ) -> [[CGRect]] {
        guard width > 0, !text.isEmpty, !segments.isEmpty else { return [] }

        let key = CacheKey(
            text: text,
            fontName: font.fontName,
            pointSize: font.pointSize,
            lineSpacing: paragraph.lineSpacing,
            alignment: Int(paragraph.alignment.rawValue),
            width: width
        )
        if key == cachedKey { return cachedRects }

        cachedKey = key
        cachedRects = layout(segments: segments, text: text, font: font, paragraph: paragraph, width: width)
        return cachedRects
    }

    func invalidate() {
        cachedKey = nil
        cachedRects = []
    }

    // MARK: - 合成（primuse：每字各画一份）

    /// 这一帧 mask 该画哪些笔 —— **纯几何**，不碰 `CALayer`。
    ///
    /// 🔴 每个 `progress > 0` 的词都产出**自己的**笔；一个词跨行时，前面整段实心、
    /// 只在末段做柔边（见下），所以一个词可能一次吐好几笔。
    static func strokes(
        segments: [KaraokeSweepPolicy.Segment],
        rects: [[CGRect]],
        at time: TimeInterval,
        edgeHalf: CGFloat = Tuning.maskEdgeWidth / 2
    ) -> [Stroke] {
        guard segments.count == rects.count else { return [] }

        var strokes: [Stroke] = []
        for (index, segment) in segments.enumerated() {
            let progress = KaraokeSweepPolicy.sweepProgress(for: segment, at: time)
            let segmentRects = rects[index]
            guard !segmentRects.isEmpty, progress > 0 else { continue }

            if progress >= 1 {
                for rect in segmentRects { strokes.append(.fill(rect)) }
                continue
            }

            // 跨行：前面整段实心，只在最后一段做柔边（与 primuse「按顺序扣」同口径）。
            let total = segmentRects.reduce(0) { $0 + $1.width }
            var remaining = CGFloat(progress) * total
            for rect in segmentRects {
                if remaining >= rect.width {
                    strokes.append(.fill(rect))
                    remaining -= rect.width
                    continue
                }
                let local = rect.width > 0 ? remaining / rect.width : 0
                let lower = min(max(local - edgeHalf, 0), 1)
                let upper = min(max(local + edgeHalf, lower), 1)
                strokes.append(.soft(rect: rect, lower: lower, upper: upper))
                break
            }
        }
        return strokes
    }

    /// 把各词贡献合成**一张** mask 图（alpha＝露出顶字的多少）。
    static func composeMaskImage(
        size: CGSize,
        scale: CGFloat,
        strokes: [Stroke]
    ) -> CGImage? {
        guard size.width > 0, size.height > 0, !strokes.isEmpty else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            for stroke in strokes {
                switch stroke {
                case .fill(let rect):
                    cg.setFillColor(AppColor.karaokeMaskLit)
                    cg.fill(rect)
                case .soft(let rect, let lower, let upper):
                    drawSoftEdge(in: rect, lower: lower, upper: upper, context: cg)
                }
            }
        }
        return image.cgImage
    }

    // MARK: - 私有

    private static func drawSoftEdge(
        in rect: CGRect, lower: CGFloat, upper: CGFloat, context: CGContext
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        let colors = [
            AppColor.karaokeMaskLit, AppColor.karaokeMaskLit,
            AppColor.karaokeMaskClear, AppColor.karaokeMaskClear
        ] as CFArray
        var locations: [CGFloat] = [0, lower, upper, 1]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: &locations
        ) else { return }

        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.midY),
            end: CGPoint(x: rect.maxX, y: rect.midY),
            options: []
        )
        context.restoreGState()
    }

    private func layout(
        segments: [KaraokeSweepPolicy.Segment],
        text: String,
        font: UIFont,
        paragraph: NSParagraphStyle,
        width: CGFloat
    ) -> [[CGRect]] {
        storage.setAttributedString(
            NSAttributedString(string: text, attributes: [
                .font: font,
                .paragraphStyle: paragraph
            ])
        )
        container.size = CGSize(width: width, height: Self.unboundedHeight)
        layoutManager.ensureLayout(for: container)

        var result: [[CGRect]] = []
        result.reserveCapacity(segments.count)
        for segment in segments {
            var rects: [CGRect] = []
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: segment.range, actualCharacterRange: nil
            )
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                rects.append(rect)
            }
            result.append(rects)
        }
        return result
    }
}
