import Foundation

/// 海报画幅。取值**既是导出像素尺寸，也是渲染时的点数**（海报按 `scale = 1` 渲染）——
/// 画布是一张固定设计稿，跟屏幕尺寸、安全区、深浅色都无关。
enum LyricsPosterCanvas: String, Hashable, CaseIterable {
    /// 1:1 —— 聊天和头像。
    case square
    /// 4:5 —— 图墙不裁的那种竖版。
    case portrait
    /// 9:16 —— 全屏故事 / 状态。
    case story

    /// 设计稿基准宽度。渲染点数和导出像素都从它算。
    static let referenceWidth: Double = 1080

    var pixelWidth: Double { Self.referenceWidth }

    var pixelHeight: Double {
        switch self {
        case .square: return 1080
        case .portrait: return 1350
        case .story: return 1920
        }
    }

    /// 分段控件上的名字。
    var title: String {
        switch self {
        case .square: return "方形"
        case .portrait: return "竖版"
        case .story: return "全屏"
        }
    }
}

/// 海报风格的标识。用**字符串值**而不是枚举：以后加一种风格（哪怕来自别处）
/// 不用回来改任何一处 `switch`。
struct LyricsPosterStyleID: RawRepresentable, Hashable, Codable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
}

extension LyricsPosterStyleID {
    /// 模糊封面铺满，歌词落在一块磨砂卡片上。
    static let auroraGlass = LyricsPosterStyleID("aurora_glass")
    /// 封面当作唱片；动态海报里唱片在转。
    static let vinyl = LyricsPosterStyleID("vinyl")
    /// 编辑排版的黑字纸面，不需要封面。
    static let magazine = LyricsPosterStyleID("magazine")
    /// 电影字幕，压在一条宽银幕画格下。
    static let filmStill = LyricsPosterStyleID("film_still")
    /// 封面取色的渐变加超大引号。
    static let gradientQuote = LyricsPosterStyleID("gradient_quote")
    /// 深夜霓虹，光晕跟着唱到的行走。
    static let neonNight = LyricsPosterStyleID("neon_night")
    /// 拍立得相纸加手写感落款。
    static let polaroid = LyricsPosterStyleID("polaroid")
    /// 磁带 J 卡，等宽字。
    static let cassette = LyricsPosterStyleID("cassette")
}

/// 选择器和导出流程要的一个风格的**全部元信息** —— 不用实例化它的渲染器就能问出来。
struct LyricsPosterStyleDescriptor: Hashable, Identifiable {
    let id: LyricsPosterStyleID
    /// 选择器上显示的名字。
    let name: String
    let symbolName: String
    /// 用户还没给这个风格挑过画幅时用的那一档。
    let preferredCanvas: LyricsPosterCanvas
    let supportedCanvases: [LyricsPosterCanvas]
    /// 靠封面立起来的风格，遇到封面始终取不到的歌就立不住 —— 目录把它藏起来，
    /// 而不是在封面该在的地方画一块占位方块。
    let requiresArtwork: Bool
    let supportsMotion: Bool
    /// 选择器里的先后。
    let order: Int

    init(
        id: LyricsPosterStyleID,
        name: String,
        symbolName: String,
        preferredCanvas: LyricsPosterCanvas = .portrait,
        supportedCanvases: [LyricsPosterCanvas] = LyricsPosterCanvas.allCases,
        requiresArtwork: Bool = false,
        supportsMotion: Bool = true,
        order: Int
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.preferredCanvas = preferredCanvas
        self.supportedCanvases = supportedCanvases
        self.requiresArtwork = requiresArtwork
        self.supportsMotion = supportsMotion
        self.order = order
    }

    /// 在支持范围内用用户要的那一档，否则退回这个风格的默认档。
    func canvas(preferring requested: LyricsPosterCanvas?) -> LyricsPosterCanvas {
        guard let requested, supportedCanvases.contains(requested) else { return preferredCanvas }
        return requested
    }
}

/// 内置风格清单 ＋「一首歌到底能用哪几种」的规则。**只到 Foundation**，
/// 排序和回退规则因此能在测试里单独跑。
enum LyricsPosterStyleCatalog {

    static let builtInDescriptors: [LyricsPosterStyleDescriptor] = [
        LyricsPosterStyleDescriptor(
            id: .auroraGlass,
            name: "极光玻璃",
            symbolName: "sparkles",
            preferredCanvas: .portrait,
            requiresArtwork: true,
            order: 0
        ),
        LyricsPosterStyleDescriptor(
            id: .gradientQuote,
            name: "渐变引句",
            symbolName: "quote.opening",
            preferredCanvas: .portrait,
            requiresArtwork: false,
            order: 1
        ),
        LyricsPosterStyleDescriptor(
            id: .magazine,
            name: "杂志",
            symbolName: "newspaper",
            preferredCanvas: .portrait,
            requiresArtwork: false,
            order: 2
        ),
        LyricsPosterStyleDescriptor(
            id: .vinyl,
            name: "黑胶",
            symbolName: "opticaldisc",
            preferredCanvas: .square,
            requiresArtwork: true,
            order: 3
        ),
        LyricsPosterStyleDescriptor(
            id: .filmStill,
            name: "电影",
            symbolName: "film",
            preferredCanvas: .story,
            requiresArtwork: true,
            order: 4
        ),
        LyricsPosterStyleDescriptor(
            id: .neonNight,
            name: "霓虹",
            symbolName: "bolt.fill",
            preferredCanvas: .story,
            requiresArtwork: false,
            order: 5
        ),
        LyricsPosterStyleDescriptor(
            id: .polaroid,
            name: "拍立得",
            symbolName: "camera",
            preferredCanvas: .portrait,
            requiresArtwork: true,
            order: 6
        ),
        LyricsPosterStyleDescriptor(
            id: .cassette,
            name: "磁带",
            symbolName: "recordingtape",
            preferredCanvas: .square,
            requiresArtwork: false,
            order: 7
        ),
    ]

    /// 一首歌能用哪几种风格，按选择器顺序。
    ///
    /// `requiresMotion` 收窄到能动的那些 —— 存过的"动态"偏好落到一个只出静图的风格上，
    /// 不该悄悄做出一张实况照片永远不动的东西。
    static func availableDescriptors(
        in descriptors: [LyricsPosterStyleDescriptor] = builtInDescriptors,
        hasArtwork: Bool,
        requiresMotion: Bool = false
    ) -> [LyricsPosterStyleDescriptor] {
        descriptors
            .filter { hasArtwork || !$0.requiresArtwork }
            .filter { !requiresMotion || $0.supportsMotion }
            .sorted { $0.order < $1.order }
    }

    /// 该显示哪一种：存过的偏好在还能用时优先，否则退回第一个可用的。
    static func resolvedDescriptor(
        preferred: LyricsPosterStyleID?,
        in descriptors: [LyricsPosterStyleDescriptor] = builtInDescriptors,
        hasArtwork: Bool,
        requiresMotion: Bool = false
    ) -> LyricsPosterStyleDescriptor? {
        let available = availableDescriptors(
            in: descriptors,
            hasArtwork: hasArtwork,
            requiresMotion: requiresMotion
        )
        if let preferred, let match = available.first(where: { $0.id == preferred }) {
            return match
        }
        return available.first
    }

    static func descriptor(
        for id: LyricsPosterStyleID,
        in descriptors: [LyricsPosterStyleDescriptor] = builtInDescriptors
    ) -> LyricsPosterStyleDescriptor? {
        descriptors.first { $0.id == id }
    }
}

/// 海报自己的设计稿令牌 —— 只放**跨风格共用**的那几个数 ＋ 与画布网格无关的全局参数。
///
/// ⚠️ 各风格内部的排版数值**留在各自文件里**：它们是 1080 设计稿网格上的取值，
/// 都经 `LyricsPosterRenderContext.scaled(_:)` 换算成实际点数，跟界面层那套
/// 屏幕无关的点值不是一回事（`CoverPalette.Tuning` 同理）。
enum LyricsPosterMetrics {

    /// 取封面用的边长（点）。海报最宽 1080，取 1024 足够，再大只是多占内存。
    static let artworkSide: CGFloat = 1024
    /// 封面预模糊的半径。背景糊不掉就没法读词，所以走 Core Image 先糊一次。
    static let artworkBlurRadius: Double = 48

    /// 导出帧率。实况照片的原生素材本就是低帧率短片，24 帧已经够顺。
    static let exportFrameRate = 24

    /// 预览两侧留白（点）。预览宽度要扣掉它。
    static let previewHorizontalMargin: CGFloat = 20
    /// 预览最多占这么高，否则竖版画幅会把风格选择器挤出首屏。
    static let previewMaximumHeight: CGFloat = 420

    /// 导出物的临时目录名。
    static let exportDirectoryName = "LyricsPosters"
}
