import SwiftUI

/// 歌词正文。**所有风格共用同一套逐行呈现规则** —— 换风格换的是画面，
/// 不是歌词的读法。
struct LyricsPosterPassageView: View {
    let context: LyricsPosterRenderContext
    let metrics: LyricsPosterTypeMetrics
    var alignment: HorizontalAlignment = .leading
    var textAlignment: TextAlignment = .leading
    /// 已唱 / 当前行的颜色。
    var primaryStyle: AnyShapeStyle
    /// 还没到的那几行。
    var pendingStyle: AnyShapeStyle
    var fontDesign: Font.Design = .rounded
    var fontWeight: Font.Weight = .bold
    var shadow: Color?

    var body: some View {
        VStack(alignment: alignment, spacing: metrics.lyricLineSpacing) {
            ForEach(Array(context.content.lines.enumerated()), id: \.element.id) { index, line in
                let reveal = context.reveal(ofLineAt: index)
                Text(line.text)
                    .font(.system(
                        size: metrics.lyricFontSize,
                        weight: fontWeight,
                        design: fontDesign
                    ))
                    .foregroundStyle(reveal > 0 ? primaryStyle : pendingStyle)
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: metrics.textWidth, alignment: frameAlignment)
                    // 逐行浮入：没到的行压暗下沉，唱到时升起。静态海报 reveal 恒为 1，
                    // 这三个修饰符全部取到中性值。
                    .opacity(0.18 + 0.82 * revealEase(reveal))
                    .offset(y: pendingOffset(reveal))
                    .blur(radius: pendingBlur(reveal))
                    .shadow(
                        color: shadow ?? .clear,
                        radius: context.scaled(18),
                        x: 0,
                        y: context.scaled(6)
                    )
            }
        }
        .frame(width: metrics.textWidth, alignment: frameAlignment)
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    /// 缓出曲线。线性揭示会让每行"匀速爬"上来，读起来像加载动画。
    private func revealEase(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return 1 - pow(1 - clamped, 2.2)
    }

    // 每个中间量都写死类型：Double（时间 / 进度）和 CGFloat（尺寸）混在一条长表达式里
    // 会把 Swift 的类型检查顶到超时。
    private func pendingOffset(_ reveal: Double) -> CGFloat {
        let remaining = CGFloat(1 - revealEase(reveal))
        return context.scaled(26) * remaining
    }

    private func pendingBlur(_ reveal: Double) -> CGFloat {
        let remaining = CGFloat(1 - revealEase(reveal))
        return context.scaled(9) * remaining
    }
}

/// 海报署名：封面缩略图 ＋ 歌名歌手 ＋ 应用名。
struct LyricsPosterCreditView: View {
    let context: LyricsPosterRenderContext
    let metrics: LyricsPosterTypeMetrics
    var titleColor: Color
    var detailColor: Color
    var showsArtwork: Bool = true
    var artworkCorner: Double = 14

    var body: some View {
        HStack(spacing: context.scaled(20)) {
            if showsArtwork, let artwork = context.artworkImage {
                artwork
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: context.scaled(96), height: context.scaled(96))
                    .clipShape(RoundedRectangle(
                        cornerRadius: context.scaled(artworkCorner),
                        style: .continuous
                    ))
            }

            VStack(alignment: .leading, spacing: context.scaled(6)) {
                Text(context.content.songTitle)
                    .font(.system(size: metrics.titleFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(titleColor)
                    .lineLimit(2)

                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.system(size: metrics.captionFontSize, weight: .medium, design: .rounded))
                        .foregroundStyle(detailColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if context.showsCredit {
                VStack(alignment: .trailing, spacing: context.scaled(4)) {
                    Image(systemName: "music.note")
                        .font(.system(size: metrics.captionFontSize * 1.1, weight: .semibold))
                    Text(context.appName)
                        .font(.system(size: metrics.captionFontSize * 0.92, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(detailColor)
            }
        }
    }

    private var subtitleText: String? {
        let parts = [context.content.artistName, context.content.albumTitle].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 封面模糊铺底。多个风格共用，顺带把动态海报的缓慢推近也放在这里。
struct LyricsPosterArtworkBackdrop: View {
    let context: LyricsPosterRenderContext
    var blurRadius: Double = 90
    var overlayOpacity: Double = 0.45

    var body: some View {
        ZStack {
            context.palette.deep
            if let artwork = context.blurredArtworkImage {
                artwork
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // 略微放大再缓推：预模糊的图边缘已经发散，不放大会露出画布底色。
                    .scaleEffect(CGFloat(1.12 + 0.08 * context.entrance))
                    .blur(radius: context.scaled(blurRadius * 0.25), opaque: true)
                    .overlay(context.palette.deep.opacity(overlayOpacity))
            } else {
                context.palette.backdropGradient
            }
        }
        // 离屏渲染不会自动裁剪溢出内容，放大后的封面必须显式切回画布。
        .frame(width: context.size.width, height: context.size.height)
        .clipped()
    }
}

/// 颗粒质感。纯色渐变在大画布上会有明显色带，叠一层极淡噪点就消失。
struct LyricsPosterGrainOverlay: View {
    let context: LyricsPosterRenderContext
    var opacity: Double = 0.05

    var body: some View {
        Canvas { canvasContext, size in
            var generator = SeededRandomGenerator(seed: 0x5EED)
            let dotSize = context.scaled(3)
            let width = Double(size.width)
            let height = Double(size.height)
            let count = Int(width * height / 2600)
            for _ in 0..<count {
                let x = Double.random(in: 0...width, using: &generator)
                let y = Double.random(in: 0...height, using: &generator)
                let alpha = Double.random(in: 0.25...1, using: &generator)
                let dot = CGRect(x: CGFloat(x), y: CGFloat(y), width: dotSize, height: dotSize)
                canvasContext.fill(Path(ellipseIn: dot), with: .color(LyricsPosterInk.grain.opacity(alpha)))
            }
        }
        .opacity(opacity)
        .blendMode(.overlay)
        .allowsHitTesting(false)
    }
}

/// 固定种子的随机源 —— 噪点必须每帧一致，否则动态海报会"沙沙"闪。
struct SeededRandomGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
