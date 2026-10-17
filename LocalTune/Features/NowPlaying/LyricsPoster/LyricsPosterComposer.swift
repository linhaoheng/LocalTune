import SwiftUI
import UIKit

/// 歌词海报面板的状态机：持有一份歌词快照，负责取封面、算配色、给出渲染上下文。
///
/// 🔴 是"快照"而不是"实时绑定"：面板开着的时候用户可能继续听、切歌，海报上的内容
/// 不该跟着变 —— 用户挑的是刚才那几句。
///
/// ## 线程
///
/// **整个类都是主线程的**（`@MainActor`）：它由页面动作创建、被 SwiftUI 面板读写。
/// 只有取封面那一步（读盘 ＋ 预模糊）在后台跑，回主线程才落进 `@Published`。
@MainActor
final class LyricsPosterComposer: ObservableObject, Identifiable {

    /// 每开一次面板都是一份新快照，用它驱动 `sheet(item:)`。
    let id = UUID()

    // MARK: - 内容（快照）

    private let songTitle: String
    private let artistName: String?
    private let albumTitle: String?
    private let year: Int?
    /// 这首歌能被选上来的所有行（已滤掉空行）。面板开着期间不变。
    let lines: [LyricsPosterLine]

    @Published private(set) var selection: [String]
    /// 最近一次被拒绝的选句，界面给完提示就清空。
    @Published var rejection: LyricsPosterSelectionRejection?

    // MARK: - 外观

    @Published var styleID: LyricsPosterStyleID
    @Published var canvas: LyricsPosterCanvas
    /// 导出成实况照片（动态）还是静态图。风格不支持动态时面板把开关置灰。
    @Published var prefersMotion: Bool
    @Published var showsCredit: Bool

    // MARK: - 导出状态

    /// 动态导出要逐帧渲染一百多张，面板据此挂进度条、并在关页时取消。
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0

    // MARK: - 资源

    @Published private(set) var artwork: UIImage?
    @Published private(set) var blurredArtwork: UIImage?
    @Published private(set) var palette: LyricsPosterPalette = .fallback
    @Published private(set) var isLoadingArtwork = false

    // MARK: - 依赖

    private let artworkPath: String?
    private let artworkProvider: ArtworkProvider
    private let paletteProvider: (String?) -> ArtworkPalette?
    private let settings: AppSettings

    init(
        songTitle: String,
        artistName: String?,
        albumTitle: String?,
        year: Int?,
        lines: [LyricsPosterLine],
        selection: [String],
        artworkPath: String?,
        styleID: LyricsPosterStyleID?,
        canvas: LyricsPosterCanvas?,
        prefersMotion: Bool,
        showsCredit: Bool,
        artworkProvider: @escaping ArtworkProvider,
        paletteProvider: @escaping (String?) -> ArtworkPalette?,
        settings: AppSettings
    ) {
        self.songTitle = songTitle
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.year = year
        self.lines = lines
        self.selection = selection
        self.artworkPath = artworkPath
        self.artworkProvider = artworkProvider
        self.paletteProvider = paletteProvider
        self.settings = settings
        self.prefersMotion = prefersMotion
        self.showsCredit = showsCredit

        // 封面还没加载完，先按"无封面"解析风格；封面到了再放宽一次。
        let resolved = LyricsPosterStyleRegistry.resolvedDescriptor(
            preferred: styleID,
            hasArtwork: artworkPath != nil,
            requiresMotion: prefersMotion
        )
        self.styleID = resolved?.id ?? .gradientQuote
        self.canvas = resolved?.canvas(preferring: canvas) ?? .portrait
    }

    // MARK: - 派生内容

    var content: LyricsPosterContent {
        LyricsPosterSelectionPolicy.content(
            songTitle: songTitle,
            artistName: artistName,
            albumTitle: albumTitle,
            year: year,
            lines: lines,
            selection: selection
        )
    }

    var hasSelection: Bool { !selection.isEmpty }

    var hasArtwork: Bool { artwork != nil }

    var motionPlan: LyricsPosterMotionPlan {
        LyricsPosterMotionPolicy.plan(for: content)
    }

    var descriptor: LyricsPosterStyleDescriptor? {
        LyricsPosterStyleRegistry.descriptor(for: styleID)
    }

    var availableDescriptors: [LyricsPosterStyleDescriptor] {
        LyricsPosterStyleRegistry.availableDescriptors(hasArtwork: hasArtwork, requiresMotion: prefersMotion)
    }

    var supportedCanvases: [LyricsPosterCanvas] {
        descriptor?.supportedCanvases ?? LyricsPosterCanvas.allCases
    }

    var renderer: (any LyricsPosterStyleRendering)? {
        LyricsPosterStyleRegistry.renderer(for: styleID)
    }

    /// 当前风格 ＋ 画幅下歌词已经排不进版面。导出的图会被裁，所以要明说。
    var layoutOverflows: Bool {
        guard hasSelection, let renderer else { return false }
        return renderer.metrics(for: context(at: 0, isMotion: false)).overflows
    }

    // MARK: - 选句

    func toggle(_ id: String) {
        let result = LyricsPosterSelectionPolicy.toggling(id, in: lines, selection: selection)
        selection = result.selection
        rejection = result.rejection
    }

    func canExtend(to id: String) -> Bool {
        LyricsPosterSelectionPolicy.canExtend(to: id, in: lines, selection: selection)
    }

    func isSelected(_ id: String) -> Bool {
        selection.contains(id)
    }

    // MARK: - 外观

    /// 换风格时把画幅收敛到该风格支持的范围，并存下这个偏好。
    func select(style: LyricsPosterStyleDescriptor) {
        styleID = style.id
        canvas = style.canvas(preferring: canvas)
        settings.lyricPosterStyleID = style.id.rawValue
    }

    /// 换画幅 —— 面板的分段控件直接写 `canvas`，这里补上持久化。
    func setCanvas(_ value: LyricsPosterCanvas) {
        canvas = value
        settings.lyricPosterCanvas = value.rawValue
    }

    func setShowsCredit(_ value: Bool) {
        showsCredit = value
        settings.lyricPosterShowsCredit = value
    }

    /// 切换动静。当前风格若只出静图，就换成第一个能动的 —— 不能悄悄给用户一张
    /// "永远不动"的实况照片。
    func setPrefersMotion(_ value: Bool) {
        prefersMotion = value
        settings.lyricPosterPrefersMotion = value
        guard value else { return }
        if let resolved = LyricsPosterStyleRegistry.resolvedDescriptor(
            preferred: styleID,
            hasArtwork: hasArtwork,
            requiresMotion: true
        ), resolved.id != styleID {
            styleID = resolved.id
            canvas = resolved.canvas(preferring: canvas)
        }
    }

    // MARK: - 资源加载

    /// 取封面 ＋ 配色 ＋ 预模糊。取不到就把依赖封面的风格换掉，绝不画个空壳。
    func loadArtwork() async {
        guard let path = artworkPath, artwork == nil, !isLoadingArtwork else { return }
        isLoadingArtwork = true
        defer { isLoadingArtwork = false }

        let provider = artworkProvider
        let paletteSource = paletteProvider
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.loadArtworkResources(path: path, provider: provider, paletteSource: paletteSource)
        }.value

        guard let loaded else {
            // 封面没取到（源离线、文件里根本没有内嵌图）。依赖封面的风格这时只会画出
            // 一个空壳，直接换成不需要封面的风格。
            if descriptor?.requiresArtwork == true,
               let fallback = LyricsPosterStyleRegistry.resolvedDescriptor(
                   preferred: nil, hasArtwork: false, requiresMotion: prefersMotion
               ) {
                styleID = fallback.id
                canvas = fallback.canvas(preferring: canvas)
            }
            return
        }

        artwork = loaded.image
        blurredArtwork = loaded.blurred
        palette = loaded.palette

        // 封面到位后，依赖封面的风格才成为可选项；用户存过的偏好这时可以兑现。
        if let restored = LyricsPosterStyleRegistry.resolvedDescriptor(
            preferred: styleID, hasArtwork: true, requiresMotion: prefersMotion
        ), restored.id != styleID {
            styleID = restored.id
            canvas = restored.canvas(preferring: canvas)
        }
    }

    /// 后台取图那一步的产物。主线程只负责把它摆上 `@Published`。
    private struct ArtworkResources {
        let image: UIImage
        let blurred: UIImage?
        let palette: LyricsPosterPalette
    }

    private nonisolated static func loadArtworkResources(
        path: String,
        provider: ArtworkProvider,
        paletteSource: (String?) -> ArtworkPalette?
    ) -> ArtworkResources? {
        let side = CGSize(width: LyricsPosterMetrics.artworkSide, height: LyricsPosterMetrics.artworkSide)
        guard let image = provider(path, side, 1) else { return nil }
        return ArtworkResources(
            image: image,
            blurred: LyricsPosterRenderer.blurredArtwork(from: image),
            palette: LyricsPosterPalette.make(from: paletteSource(path))
        )
    }

    // MARK: - 渲染

    func context(at time: TimeInterval, isMotion: Bool) -> LyricsPosterRenderContext {
        let plan = motionPlan
        return LyricsPosterRenderContext(
            content: content,
            canvas: canvas,
            palette: palette,
            artwork: artwork,
            blurredArtwork: blurredArtwork,
            motion: plan,
            time: isMotion ? time : plan.duration,
            isMotion: isMotion,
            showsCredit: showsCredit,
            appName: Self.appName
        )
    }

    @ViewBuilder
    func preview(at time: TimeInterval, isMotion: Bool) -> some View {
        if let renderer {
            LyricsPosterRenderer.makeView(
                style: renderer,
                context: context(at: time, isMotion: isMotion)
            )
        } else {
            LyricsPosterInk.backdrop()
        }
    }

    // MARK: - 导出

    /// 静态海报 PNG —— 写到临时目录，返回文件 URL（分享 / 存相册都用它）。
    func exportStillImage() throws -> URL {
        guard let renderer else { throw LyricsPosterExportError.noRenderer }
        return try LyricsPosterExporter.writeStillImage(
            style: renderer,
            context: context(at: 0, isMotion: false),
            baseName: exportBaseName
        )
    }

    /// 实况照片。静图与视频落在同一个临时目录，存相册时必须一起提交。
    ///
    /// 逐帧渲染走 `LyricsPosterRenderer.renderCGImage` —— 跟预览、跟静态导出**同一个**
    /// 渲染入口，保证"所见"就是"所存"。
    ///
    /// ⚠️ 一百多帧都在主线程上渲染（`ImageRenderer` 只能在主线程跑），所以每一帧之间
    /// 让一次线程，进度条和取消键才活得了。
    func exportLivePhoto() async throws -> LyricsPosterLivePhotoBundle {
        guard let renderer else { throw LyricsPosterExportError.noRenderer }
        isExporting = true
        exportProgress = 0
        defer {
            isExporting = false
            exportProgress = 0
        }

        let plan = motionPlan
        let directory = try LyricsPosterExporter.makeExportDirectory()
        let size = CGSize(width: canvas.pixelWidth, height: canvas.pixelHeight)

        return try await LyricsPosterLivePhotoWriter.write(
            plan: plan,
            size: size,
            directory: directory,
            baseName: exportBaseName,
            frame: { [weak self] index in
                guard let self else { return nil }
                let frameContext = self.context(at: plan.time(ofFrame: index), isMotion: true)
                return LyricsPosterRenderer.renderCGImage(style: renderer, context: frameContext)
            },
            onProgress: { [weak self] progress in
                self?.exportProgress = progress
            }
        )
    }

    private var exportBaseName: String {
        let raw = [songTitle, artistName].compactMap { $0 }.joined(separator: "-")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = raw.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .prefix(48)
        let stamp = Int(Date().timeIntervalSince1970)
        return "\(String(sanitized))-\(stamp)"
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "LocalTune"
    }
}

// MARK: - 从播放中的歌曲构造

extension LyricsPosterComposer {

    /// 播放页入口。`playbackPosition` 用来定位"当前正唱的那句"作为默认选段。
    static func make(
        track: Track,
        lyrics: [LyricsLine],
        playbackPosition: TimeInterval,
        artworkProvider: @escaping ArtworkProvider,
        paletteProvider: @escaping (String?) -> ArtworkPalette?,
        settings: AppSettings
    ) -> LyricsPosterComposer {
        let lines = LyricsPosterSelectionPolicy.selectableLines(from: lyrics)
        let selection = LyricsPosterSelectionPolicy.defaultSelection(
            in: lines,
            playbackPosition: playbackPosition
        )

        return LyricsPosterComposer(
            songTitle: track.title,
            artistName: track.artist,
            albumTitle: track.album,
            year: Self.year(from: track.releaseDate),
            lines: lines,
            selection: selection,
            artworkPath: track.artworkPath,
            styleID: LyricsPosterStyleID(rawValue: settings.lyricPosterStyleID),
            canvas: LyricsPosterCanvas(rawValue: settings.lyricPosterCanvas),
            prefersMotion: settings.lyricPosterPrefersMotion,
            showsCredit: settings.lyricPosterShowsCredit,
            artworkProvider: artworkProvider,
            paletteProvider: paletteProvider,
            settings: settings
        )
    }

    /// 发行日期原样存着（`"2019"` / `"2019-05-01"` 都行），这里只取前四位当年份。
    private static func year(from releaseDate: String?) -> Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }
}
