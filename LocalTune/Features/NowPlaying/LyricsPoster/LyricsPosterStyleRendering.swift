import SwiftUI
import UIKit

// MARK: - 调色板

/// 海报配色。取自封面主色；没有封面（或封面取不到色）时退回一套中性夜色 ——
/// 而不是硬套品牌色：灰度封面配上品牌色会像贴错了图。
struct LyricsPosterPalette: Equatable {
    var accent: Color
    var secondary: Color
    /// 暗部。取色链不提供"暗色"这一档，直接用播放页那张深底（跟背景取色同源）。
    var deep: Color

    static let fallback = LyricsPosterPalette(
        accent: Color(uiColor: AppColor.NowPlayingBackdrop.fallbackPalette.primary),
        secondary: Color(uiColor: AppColor.NowPlayingBackdrop.fallbackPalette.tertiary),
        deep: Color(uiColor: AppColor.nowPlayingBackground)
    )

    /// 复用播放页那套封面取色（前三名进槽）。入口在装配层注入，这里只管把三个槽翻译成颜色。
    static func make(from source: ArtworkPalette?) -> LyricsPosterPalette {
        guard let source else { return .fallback }
        return LyricsPosterPalette(
            accent: Self.color(source.primary),
            secondary: Self.color(source.tertiary),
            deep: Color(uiColor: AppColor.nowPlayingBackground)
        )
    }

    /// 深色风格统一用 主色 → 次色 → 暗部 三段，免得每种风格各写一套。
    var backdropGradient: LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.92), secondary.opacity(0.86), deep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static func color(_ value: PaletteColor) -> Color {
        Color(red: value.red, green: value.green, blue: value.blue)
    }
}

// MARK: - 墨色

/// 海报墨色。
///
/// 一张海报是**导出的图片**：它的白与黑是**画面内容**，必须与系统浅色/深色主题无关 ——
/// 所以不走 `AppColor`（那是界面令牌，会跟着主题变），自成一表。
///
/// 它只回答一个问题 —— **这张图用白墨还是黑墨**；深浅（`opacity`）仍由风格给：
/// 同一档在八种风格里本就不同（杂志的未唱行比极光淡），收成同一个数会让八种风格坍成一张脸。
enum LyricsPosterInk: Equatable {
    /// 深色风格：白墨。
    case light
    /// 浅色风格：纸上的那支墨（杂志偏冷、拍立得偏暖）。
    case paper(Color)

    /// 带深浅的墨 —— 正文、未唱行、说明字、细线、装饰都用它。
    func color(_ opacity: Double) -> Color {
        solid.opacity(opacity)
    }

    /// 不透明的墨 —— 正在唱的那行、标题。
    var solid: Color {
        switch self {
        case .light: return Color.white
        case .paper(let ink): return ink
        }
    }

    /// 投影 / 暗角。恒为黑 —— 浅色风格也压黑。
    static func shade(_ opacity: Double) -> Color {
        Color.black.opacity(opacity)
    }

    /// 实底：电影黑边、磁带带窗、预览兜底。与墨色无关，恒为黑。
    static func backdrop(_ opacity: Double = 1) -> Color {
        Color.black.opacity(opacity)
    }

    /// 颗粒噪点 —— 靠 `overlay` 混合提亮，恒为白（浅色风格里也是白）。
    static let grain = Color.white

    /// 遮罩的「显示」端 —— 遮蔽按亮度工作，恒为不透明白。
    static let mask = Color.white
}

// MARK: - 渲染上下文

/// 渲染一帧海报要的全部输入。
///
/// 是一份快照：用户在面板里继续听歌、切歌，海报上的内容不跟着变，
/// 所以风格实现**不许回头读播放器或任何全局状态**。
struct LyricsPosterRenderContext {
    let content: LyricsPosterContent
    let canvas: LyricsPosterCanvas
    let palette: LyricsPosterPalette
    let artwork: UIImage?
    /// 预先用 Core Image 糊好的封面（背景糊不掉就没法读词；SwiftUI 的 `.blur` 在离屏渲染里不稳）。
    let blurredArtwork: UIImage?
    /// 动态时间线。静态帧就是时间线末尾那一帧 —— 所以静态渲染也带着它。
    let motion: LyricsPosterMotionPlan
    /// 当前帧在时间线上的位置。
    let time: TimeInterval
    /// 正在导出 / 预览动态。静态时所有行直接呈现完成态，不做入场。
    let isMotion: Bool
    /// 右下角的署名。
    let showsCredit: Bool
    let appName: String

    var size: CGSize {
        CGSize(width: canvas.pixelWidth, height: canvas.pixelHeight)
    }

    var artworkImage: Image? {
        artwork.map { Image(uiImage: $0) }
    }

    var blurredArtworkImage: Image? {
        (blurredArtwork ?? artwork).map { Image(uiImage: $0) }
    }

    var hasArtwork: Bool { artwork != nil }

    /// 歌词可用的字号与宽度。
    ///
    /// `reservedHeight` 是这个风格版面上**除歌词以外**的固定高度（封面、唱片、画格、署名、
    /// 各段 padding 与 spacing 之和，按 1080 宽的设计稿计）。歌词的高度配额必须从画布高度里
    /// 扣掉它们再分 —— 写死成"画布高度的百分之多少"的话，同一个风格换到方形画幅就会被
    /// 固定元素挤出画布，而离屏渲染只会把溢出的部分裁掉。
    func metrics(
        textWidthRatio: Double = LyricsPosterLayoutPolicy.defaultTextWidthRatio,
        reservedHeight: Double = 0,
        breathingRatio: Double = 0.10
    ) -> LyricsPosterTypeMetrics {
        let canvasHeight = canvas.pixelHeight
        let floor = canvasHeight * 0.16
        let breathing = max(canvasHeight - reservedHeight - canvasHeight * breathingRatio, floor)
        var resolved = LyricsPosterLayoutPolicy.metrics(
            for: content,
            canvas: canvas,
            textWidthRatio: textWidthRatio,
            lyricHeightRatio: breathing / canvasHeight
        )
        if resolved.overflows {
            // 上下留白是"好看"不是"必须"。挤不下的时候先把它让出来，真的还放不下再让 overflows 立着。
            let withoutBreathing = max(canvasHeight - reservedHeight, floor)
            if withoutBreathing > breathing {
                resolved = LyricsPosterLayoutPolicy.metrics(
                    for: content,
                    canvas: canvas,
                    textWidthRatio: textWidthRatio,
                    lyricHeightRatio: withoutBreathing / canvasHeight
                )
            }
        }
        return resolved
    }

    /// 某一行的呈现进度。静态海报恒为 1。
    func reveal(ofLineAt index: Int) -> Double {
        guard isMotion else { return 1 }
        return motion.reveal(ofLineAt: index, at: time)
    }

    /// 整体入场进度（背景缩放 / 装饰浮入），0…1。
    var entrance: Double {
        guard isMotion, motion.duration > 0 else { return 1 }
        return min(max(time / motion.duration, 0), 1)
    }

    /// 按画布宽度换算设计稿上的尺寸 —— 1080 宽是基准。
    func scaled(_ value: Double) -> CGFloat {
        CGFloat(value * canvas.pixelWidth / LyricsPosterCanvas.referenceWidth)
    }
}

// MARK: - 风格适配器

/// 内置风格的画幅、排序、是否依赖封面都由目录定义，渲染实现只按 id 取回来 ——
/// 名称、图标、顺序**只在目录里写这一份**，风格实现不再各写一遍。
/// id 对不上时给一份保守兜底（排到最后），免得因为一次改名就崩。
func builtInPosterDescriptor(_ id: LyricsPosterStyleID) -> LyricsPosterStyleDescriptor {
    LyricsPosterStyleCatalog.descriptor(for: id)
        ?? LyricsPosterStyleDescriptor(
            id: id,
            name: "歌词海报",
            symbolName: "text.below.photo",
            order: .max
        )
}

/// 一种海报风格。新增风格 = 实现这个协议 ＋ 在注册表里登记一次，
/// 其余各处（选择器、导出、偏好）都不用改。
@MainActor
protocol LyricsPosterStyleRendering {
    var descriptor: LyricsPosterStyleDescriptor { get }
    /// 这个风格给歌词分到的字号与宽度。单独暴露出来，面板才能在装不下时提醒换画幅。
    func metrics(for context: LyricsPosterRenderContext) -> LyricsPosterTypeMetrics
    /// 画满整块画布。调用方已经把画布尺寸框好，实现内部不要再加外边距以外的 frame。
    func makeBody(context: LyricsPosterRenderContext) -> AnyView
}

/// 可用风格的登记处。
///
/// ⚠️ 它是一张**纯静态表**（风格都是无状态的 `struct`），不是单例 ——
/// 项目里不许自造 `Xxx.shared` 那种全局取用点。
@MainActor
enum LyricsPosterStyleRegistry {

    /// 全部内置风格。顺序由各自的 `descriptor.order` 定，这里只负责列出。
    static let all: [any LyricsPosterStyleRendering] = [
        AuroraGlassPosterStyle(),
        GradientQuotePosterStyle(),
        MagazinePosterStyle(),
        VinylPosterStyle(),
        FilmStillPosterStyle(),
        NeonNightPosterStyle(),
        PolaroidPosterStyle(),
        CassettePosterStyle(),
    ]

    static func renderer(for id: LyricsPosterStyleID) -> (any LyricsPosterStyleRendering)? {
        all.first { $0.descriptor.id == id }
    }

    /// 某个风格的元信息。渲染器自己就带一份 —— 直接问它，不必另铺一份映射。
    static func descriptor(for id: LyricsPosterStyleID) -> LyricsPosterStyleDescriptor? {
        renderer(for: id)?.descriptor
    }

    /// 已注册风格的描述，按 `descriptor.order` 排。
    static var descriptors: [LyricsPosterStyleDescriptor] {
        all.map(\.descriptor).sorted { $0.order < $1.order }
    }

    static func availableDescriptors(
        hasArtwork: Bool,
        requiresMotion: Bool
    ) -> [LyricsPosterStyleDescriptor] {
        LyricsPosterStyleCatalog.availableDescriptors(
            in: descriptors,
            hasArtwork: hasArtwork,
            requiresMotion: requiresMotion
        )
    }

    static func resolvedDescriptor(
        preferred: LyricsPosterStyleID?,
        hasArtwork: Bool,
        requiresMotion: Bool
    ) -> LyricsPosterStyleDescriptor? {
        LyricsPosterStyleCatalog.resolvedDescriptor(
            preferred: preferred,
            in: descriptors,
            hasArtwork: hasArtwork,
            requiresMotion: requiresMotion
        )
    }
}
