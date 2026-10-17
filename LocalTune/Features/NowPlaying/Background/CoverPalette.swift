import CoreGraphics
import Foundation

/// 一张封面的颜色池 —— RGB 桶聚类，按票数从多到少。
///
/// 🔴 **纯算法**：像素进、排好序的桶出，不碰界面、不碰线程、不存状态。
/// 取图（多大、从哪读）是装配层的事（`AppArtwork.palette`）。三个槽怎么填是
/// `ArtworkPalette` 的事；换成渐变端色是 `BackdropGradient` 的事。
///
/// 桶的规则对齐桌面 `LocalTune_副本10` 的 `sortedBuckets`：先到先得、灰 / 近白
/// 只进全池、彩色池最高票够多就从彩色池里挑。**不在这里缩图** —— 像素是调用方给的。
struct CoverPalette: Equatable {

    struct Swatch: Equatable {
        let color: PaletteColor
        let weight: Double
    }

    let swatches: [Swatch]

    /// 取色前装配层向 `ArtworkStore` 要的图（**像素**边长）。
    static let sourceImageSize = CGSize(width: Tuning.sourceSide, height: Tuning.sourceSide)

    /// 取色源图的倍数 —— **固定 1**，不跟屏幕走。和 `sourceImageSize` 写在同一处。
    static let sourceScale: CGFloat = Tuning.sourceScale

    /// 从一张图取色。图多大是取图层的事；这里**不缩放**。
    init?(image: CGImage) {
        guard let pixels = Self.rgbaPixels(of: image) else { return nil }
        self.init(rgbaPixels: pixels)
    }

    /// 从一块 **sRGB、预乘透明度、每点 4 字节（R G B A）** 的像素取色 —— 算法本体。
    init?(rgbaPixels pixels: [UInt8]) {
        let buckets = Self.sortedBuckets(of: pixels)
        let total = buckets.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        swatches = buckets.map { bucket in
            Swatch(color: bucket.mean, weight: Double(bucket.count) / Double(total))
        }
    }
}

// MARK: - 算法里的数

private extension CoverPalette {

    /// 取图尺寸 + 桶聚类参数。换一套取色，这些数就整组作废；不进令牌层。
    ///
    /// ⚠️ `sourceSide` / `sourceScale` 是装配层要图的约定，**不是**本类型内部再缩一次。
    /// 桶上的数与副本10 同一组；副本10 里的 600 画布 / 它那一档采样属于它的取图，不在这里。
    enum Tuning {
        /// 取色源图边长。**64** —— 见 `设计/播放页背景-取色与渐变.md` §2：
        /// 它和下面那个 `maxSamplePixels` 是一对，故意配成全采样（下面有说明）。
        static let sourceSide: CGFloat = 64
        static let sourceScale: CGFloat = 1
        /// 最多采多少个点（步长 = 总点数 / 它）。
        ///
        /// 现取 **`sourceSide` 的平方**（64² = 4096）：步长恒为 1 ⇒ **不抽样，每个像素都进桶**。
        /// 这比"跳着采"多一个好处 —— 采样点铺满整张图不依赖 `步长` 与 `边长` 互素（那是个会
        /// 悄悄退化成几条竖带的坑）。**改 `sourceSide` 时必须跟着改它**，否则采样会退化。
        static let maxSamplePixels = 4096
        /// 三个通道都差不到这么多，就算同一个桶。
        static let bucketTolerance = 0.15
        /// 三通道平均低于它算近黑，整个点扔掉。
        static let minBrightness = 0.03
        /// `(最大通道 − 最小通道) / 最大通道` 低于它算灰，不进彩色桶。
        static let grayness = 0.08
        /// 三通道平均高于它算近白，不进彩色桶。
        static let nearWhiteBrightness = 0.97
        /// 彩色桶里票数最多的那个**超过**这么多点，才从彩色桶里挑。
        static let colorfulMinPixels = 19
    }
}

// MARK: - 聚类

private extension CoverPalette {

    /// 一个桶：落进来的点的三通道**累加**和点数 —— 桶心 = 平均。
    struct Bucket {
        private var red: Double
        private var green: Double
        private var blue: Double
        private(set) var count = 1

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        var mean: PaletteColor {
            let n = Double(count)
            return PaletteColor(red: red / n, green: green / n, blue: blue / n)
        }

        func accepts(red r: Double, green g: Double, blue b: Double) -> Bool {
            let center = mean
            return abs(center.red - r) < Tuning.bucketTolerance
                && abs(center.green - g) < Tuning.bucketTolerance
                && abs(center.blue - b) < Tuning.bucketTolerance
        }

        mutating func add(red r: Double, green g: Double, blue b: Double) {
            red += r
            green += g
            blue += b
            count += 1
        }
    }

    /// 采样 → 分桶 → 选彩色还是全部 → 按票数从多到少。
    static func sortedBuckets(of pixels: [UInt8]) -> [Bucket] {
        var colorful: [Bucket] = []
        var all: [Bucket] = []
        let pixelCount = pixels.count / 4
        let step = max(1, pixelCount / Tuning.maxSamplePixels)

        for index in stride(from: 0, to: pixelCount, by: step) {
            let offset = index * 4
            let r = Double(pixels[offset]) / 255
            let g = Double(pixels[offset + 1]) / 255
            let b = Double(pixels[offset + 2]) / 255
            let brightest = max(r, g, b)
            let average = (r + g + b) / 3
            guard brightest > 0, average >= Tuning.minBrightness else { continue }

            put(red: r, green: g, blue: b, into: &all)
            let isGray = (brightest - min(r, g, b)) / brightest < Tuning.grayness
            if average > Tuning.nearWhiteBrightness || isGray { continue }
            put(red: r, green: g, blue: b, into: &colorful)
        }

        let topColorful = colorful.map(\.count).max() ?? 0
        let source = topColorful > Tuning.colorfulMinPixels ? colorful : all
        return source.sorted { $0.count > $1.count }
    }

    /// 落进**第一个**收得下它的桶；都收不下就自己开一个（先到先得，结果跟采样顺序有关）。
    static func put(red r: Double, green g: Double, blue b: Double, into buckets: inout [Bucket]) {
        if let index = buckets.firstIndex(where: { $0.accepts(red: r, green: g, blue: b) }) {
            buckets[index].add(red: r, green: g, blue: b)
        } else {
            buckets.append(Bucket(red: r, green: g, blue: b))
        }
    }
}

// MARK: - 读像素

private extension CoverPalette {

    /// 把图画进一块 **sRGB** 的 RGBA 内存里读出来。
    ///
    /// 🔴 显式 sRGB：封面可能是 P3 / 灰度 / CMYK，不统一到一个色彩空间，同一组数在不同图里不是同一个颜色。
    /// ⚠️ 内存交给 `CGContext` 只在 `withUnsafeMutableBytes` 那个闭包里有效。
    static func rgbaPixels(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
