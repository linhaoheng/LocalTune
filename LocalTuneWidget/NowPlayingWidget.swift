import AppIntents
import SwiftUI
import WidgetKit

/// 桌面 4×4「正在播放」小组件 —— 只登记 systemLarge 一族。
///
/// 内容从**快照 entry** 来（`WidgetSharedStore` 通道），视图不回头读存储、
/// 不存自己的状态：主 App 落一份，这里排一批 entry、系统按时换帧。
/// 歌词在渲染期按「快照播放头 + entry 时刻差」推进当前行。
///
/// ## 按钮两路
///
/// - iOS 17+：`Button(intent:)` 走 `AudioPlaybackIntent`，`perform` 在主 App 进程执行；
/// - iOS 16：`Link` 落地 `localtune://open/widget_action?cmd=…` 前台化主 App（由
///   `WidgetCommandRouter` 接）。iOS 16 的小组件没有可交互按钮，只有 Link。
///
/// ## 线程
///
/// 无状态：TimelineProvider 在系统给的渲染时机读通道（`UserDefaults` / 文件读，线程安全），
/// 视图是纯值。
@main
struct LocalTuneWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetSharedStore.widgetKind,
            provider: NowPlayingProvider()
        ) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("正在播放")
        .description("显示当前曲目和歌词")
        .supportedFamilies([.systemLarge])
    }
}

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetPlaybackSnapshot
    let artwork: UIImage?
}

struct NowPlayingProvider: TimelineProvider {

    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), snapshot: .empty, artwork: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let shared = Self.loadShared()
        completion(NowPlayingEntry(date: Date(), snapshot: shared.snapshot, artwork: shared.artwork))
    }

    /// 一次排一批 entry：把后面若干句歌词的切换时刻一起交给系统，由系统在本地
    /// 按时间换帧 —— 不必每句都回头叫主 App reload（那会很快耗光刷新预算）。
    ///
    /// 暂停 / 没歌词：一帧定住（`.never`），等主 App 的事件驱动 reload。
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let shared = Self.loadShared()
        let (entries, policy) = Self.schedule(
            snapshot: shared.snapshot,
            artwork: shared.artwork,
            now: Date()
        )
        completion(Timeline(entries: entries, policy: policy))
    }

    /// 读一次通道：快照与封面各取一份，同一批 entry 共用。
    private static func loadShared() -> (snapshot: WidgetPlaybackSnapshot, artwork: UIImage?) {
        (
            snapshot: WidgetSharedStore.loadSnapshot(),
            // 敢吞 `flatMap` 的空：封面读不出就占位音符，封面是缓存不挡渲染。
            artwork: WidgetSharedStore.artworkData().flatMap(UIImage.init(data:))
        )
    }

    /// 一批最多排这么多帧；再多就留到下一批，让系统到点自己来取。
    private static let maxEntriesPerBatch = 24

    private static func schedule(
        snapshot: WidgetPlaybackSnapshot,
        artwork: UIImage?,
        now: Date
    ) -> ([NowPlayingEntry], TimelineReloadPolicy) {
        func entry(at date: Date) -> NowPlayingEntry {
            NowPlayingEntry(date: date, snapshot: snapshot, artwork: artwork)
        }
        guard snapshot.isPlaying, !snapshot.lyrics.isEmpty else {
            return ([entry(at: now)], .never)
        }
        let batch = WidgetLyricsPolicy.timelineBatch(
            lines: snapshot.lyrics,
            elapsed: snapshot.elapsed,
            savedAt: Date(timeIntervalSince1970: snapshot.updatedAt),
            now: now,
            maxEntries: maxEntriesPerBatch
        )
        let policy: TimelineReloadPolicy
        if let nextBatch = batch.nextBatchAfter {
            // 留 1 s 余量：贴着 entry 边界来取，容易和上一条撞在同一时刻。
            policy = .after(nextBatch.addingTimeInterval(1))
        } else {
            policy = .never
        }
        return (batch.dates.map(entry(at:)), policy)
    }
}

struct NowPlayingWidgetView: View {

    var entry: NowPlayingEntry

    var body: some View {
        Group {
            if #available(iOS 17.0, *) {
                layout
                    .containerBackground(Color(uiColor: AppColor.widgetBackground), for: .widget)
                    .overlay {
                        ContainerRelativeShape()
                            .strokeBorder(Color(uiColor: AppColor.overlayBorder), lineWidth: 1)
                    }
            } else {
                layout
                    .background(Color(uiColor: AppColor.widgetBackground))
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: Layout.fallbackCorner,
                            style: .continuous
                        )
                        .strokeBorder(Color(uiColor: AppColor.overlayBorder), lineWidth: 1)
                    }
            }
        }
    }

    // MARK: - 布局

    private var layout: some View {
        VStack(spacing: 0) {
            header
            lyricsArea
        }
        .foregroundStyle(.white)
        .padding(.top, Layout.contentTop)
        .padding(.bottom, Layout.contentBottom)
    }

    /// 头部：封面 + 「歌名 / 艺人 + 三键」。
    ///
    /// 右列高 = 封面高（144）：文字块顶部让 `titleTopInset`、三键底部悬
    /// `controlsBottomInset` —— 标题不顶死、按钮不贴封面底边。
    /// 用 padding 表达间距，不塞占位视图。
    private var header: some View {
        HStack(alignment: .center, spacing: Layout.headerSpacing) {
            artwork
            VStack(alignment: .leading, spacing: 4) {
                Text(titleText)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .padding(.top, Layout.titleTopInset)
                if !entry.snapshot.artist.isEmpty {
                    Text(entry.snapshot.artist)
                        .font(.subheadline)
                        .opacity(0.9)
                        .lineLimit(1)
                }
                Spacer(minLength: Layout.headerGap)
                skipRow
                    .padding(.bottom, Layout.controlsBottomInset)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: Layout.headerSide,
                maxHeight: Layout.headerSide,
                alignment: .leading
            )
        }
        .padding(.leading, Layout.headerLeading)
        .padding(.trailing, Layout.contentEdge)
        .padding(.bottom, Layout.headerBottom)
    }

    private var artwork: some View {
        Group {
            if let image = entry.artwork {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(width: Layout.headerSide, height: Layout.headerSide)
        .clipShape(RoundedRectangle(cornerRadius: Layout.coverCorner, style: .continuous))
    }

    private var skipRow: some View {
        HStack(spacing: 0) {
            control(.previous, systemName: "backward.fill")
                .font(.body.weight(.semibold))
            Spacer(minLength: 0)
            control(
                .playPause,
                systemName: entry.snapshot.isPlaying ? "pause.fill" : "play.fill"
            )
            .font(.title2.weight(.semibold))
            Spacer(minLength: 0)
            control(.next, systemName: "forward.fill")
                .font(.body.weight(.semibold))
        }
    }

    /// 一颗键，两套载体：iOS 17+ 走 Intent 按钮，iOS 16 走 Link 落地页。
    @ViewBuilder
    private func control(_ command: WidgetPlaybackCommand, systemName: String) -> some View {
        if #available(iOS 17.0, *) {
            switch command {
            case .playPause: intentButton(systemName, WidgetPlayPauseIntent())
            case .next: intentButton(systemName, WidgetNextIntent())
            case .previous: intentButton(systemName, WidgetPreviousIntent())
            }
        } else {
            Link(destination: command.actionURL) {
                Image(systemName: systemName)
                    .foregroundStyle(.white)
            }
        }
    }

    @available(iOS 17.0, *)
    private func intentButton<I: AppIntent>(_ systemName: String, _ intent: I) -> some View {
        Button(intent: intent) {
            Image(systemName: systemName)
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 歌词区

    private var lyricsArea: some View {
        GeometryReader { geo in
            let window = displayWindow
            ZStack(alignment: .topLeading) {
                Text("“")
                    .font(.system(size: Layout.quoteSize, weight: .medium))
                    .offset(x: Layout.quoteOffsetX, y: Layout.quoteOffsetY)
                VStack(alignment: .leading, spacing: Layout.lyricsSpacing) {
                    ForEach(Array(window.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(
                                size: Self.fittedFontSize(
                                    for: window,
                                    availableWidth: geo.size.width - Layout.lyricsInset
                                )
                            ))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .offset(y: Layout.lyricsOffsetY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, Layout.contentEdge)
    }

    /// 展示窗口：从渲染期的播放头往后取 3 行；没有歌词给「暂无歌词」。
    private var displayWindow: [String] {
        let lines = entry.snapshot.lyrics
        guard !lines.isEmpty else { return [WidgetText.noLyrics] }
        let index = WidgetLyricsPolicy.currentIndex(at: playheadTime, in: lines)
        return WidgetLyricsPolicy.displayWindow(from: lines, currentIndex: index, maxLines: 3)
    }

    /// 渲染期播放头：快照的读数 + 落盘以来走过的秒数（在播才走）。
    private var playheadTime: TimeInterval {
        guard entry.snapshot.isPlaying else { return entry.snapshot.elapsed }
        let sinceSave = entry.date.timeIntervalSince1970 - entry.snapshot.updatedAt
        return entry.snapshot.elapsed + max(0, sinceSave)
    }

    /// 三行统一字号：按最长行**一轮比例换算**（不二分）——
    /// 22pt 量一次最长行宽，超宽就按比例缩，floor 到 0.1 再留 1pt 余量，夹在 13~22。
    private static func fittedFontSize(for lines: [String], availableWidth: CGFloat) -> CGFloat {
        let maxSize: CGFloat = Layout.lyricsMaxFontSize
        let minSize: CGFloat = Layout.lyricsMinFontSize
        guard availableWidth > 1, !lines.isEmpty else { return minSize }
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: maxSize)]
        let widest = lines.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
        guard widest > availableWidth else { return maxSize - 1 }
        let scaled = maxSize * availableWidth / widest
        let floored = (scaled * 10).rounded(.down) / 10
        return max(minSize, floored - 1)
    }

    /// 没在播（或还没装歌）时头部的标题文案 —— 展示句在这里拼，不进快照。
    private var titleText: String {
        entry.snapshot.title.isEmpty ? WidgetText.idleTitle : entry.snapshot.title
    }
}

/// 视图文案 —— 展示句归视图拼，快照里只装原始数据。
private enum WidgetText {
    static let idleTitle = "未在播放"
    static let noLyrics = "暂无歌词"
}

/// 布局常数 —— 头部封面 144pt，内容两侧 22pt；与锁屏那套令牌无关，是小组件自己的版式。
/// 数值按「大号」那一档定。
private enum Layout {
    static let headerSide: CGFloat = 144
    static let coverCorner: CGFloat = 16
    static let headerSpacing: CGFloat = 22
    static let headerLeading: CGFloat = 15
    static let headerBottom: CGFloat = 18
    static let headerGap: CGFloat = 18
    /// 文字块顶部让出的空：标题不顶死在右列上沿。
    static let titleTopInset: CGFloat = 14
    /// 三键离封面底边的悬距：按钮底部不贴齐封面。
    static let controlsBottomInset: CGFloat = 10
    /// 整个大布局的上下外边距。
    static let contentTop: CGFloat = 15
    static let contentBottom: CGFloat = 22
    static let contentEdge: CGFloat = 22
    static let quoteSize: CGFloat = 70
    static let quoteOffsetX: CGFloat = -20
    static let quoteOffsetY: CGFloat = -2
    static let lyricsSpacing: CGFloat = 12
    static let lyricsOffsetY: CGFloat = 15
    static let lyricsInset: CGFloat = 56
    static let lyricsMaxFontSize: CGFloat = 22
    static let lyricsMinFontSize: CGFloat = 13
    static let fallbackCorner: CGFloat = 22
}
