import SwiftUI

/// 歌词海报面板：预览 ＋ 风格 / 画幅 / 选项 ＋ 导出。
///
/// ## 它只管"选"和"发"
///
/// 海报长什么样由 `LyricsPosterComposer`（状态机）＋ 各风格实现决定，落盘由
/// `LyricsPosterExporter` 负责 —— 这一层只把状态摆到屏幕上、把用户的点按翻译成状态变更。
/// 它**不认识曲库、不认识播放器**：进来的是什么，画的就是什么。
///
/// ## 两个动作由宿主补上
///
/// `onDismiss` / `onShare` 由 `LyricsPosterHostingController` 装好之后填：
/// 关页和弹系统分享面板都是 UIKit 的事（iPad 上那个气泡还要锚点），SwiftUI 这边不掺和。
struct LyricsPosterShareSheet: View {

    @ObservedObject var composer: LyricsPosterComposer

    /// 关掉这一页。宿主给。
    var onDismiss: () -> Void = {}
    /// 把导出的 PNG 交给系统分享面板。宿主给。
    var onShare: (URL) -> Void = { _ in }

    @State private var isPickingLines = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    /// 存相册那一路（要等系统写盘）。关页时取消。
    @State private var exportTask: Task<Void, Never>?
    /// 动态海报分享时问一句"图片还是实况视频" —— 实况照片没法直接丢进系统分享面板。
    @State private var isShareChoicePresented = false
    /// 动态预览的起点。换风格 / 换选句时重置，让动效从头演一遍。
    @State private var previewEpoch = Date()

    /// 显式初始化：里面有 `private` 的 `@State`，合成的逐成员初始化器不会对外开放。
    init(composer: LyricsPosterComposer) {
        self.composer = composer
    }

    var body: some View {
        NavigationStack {
            // 在 `ScrollView` 外面量一次可用宽度。垂直 `ScrollView` 给子视图的高度提议是
            // `nil`，在里面用 `GeometryReader` 反推高度会拿到 10pt 的理想尺寸，预览框直接塌掉。
            GeometryReader { outer in
                panels(availableWidth: outer.size.width)
                    .navigationTitle("分享歌词")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { toolbarContent }
                    .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
                    // 选句页关掉时重置预览起点：选段变了，动效该从头演一遍。
                    .sheet(isPresented: $isPickingLines, onDismiss: { previewEpoch = Date() }) {
                        LyricsPosterLinePicker(composer: composer)
                    }
                    .alert("海报没做出来", isPresented: errorAlertBinding) {
                        Button("好", role: .cancel) { errorMessage = nil }
                    } message: {
                        Text(errorMessage ?? "")
                    }
                    .task { await composer.loadArtwork() }
                    .onDisappear { exportTask?.cancel() }
            }
        }
    }

    /// 从上到下：预览 · 风格 · 画幅 · 选项。
    private func panels(availableWidth: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                preview(availableWidth: availableWidth - LyricsPosterMetrics.previewHorizontalMargin * 2)
                styleRow
                canvasRow
                options
            }
            .padding(.horizontal, LyricsPosterMetrics.previewHorizontalMargin)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: AppColor.pageBackground))
    }

    // MARK: - 预览

    private func preview(availableWidth: CGFloat) -> some View {
        let size = previewSize(availableWidth: availableWidth)
        return VStack(spacing: 12) {
            Group {
                if composer.hasSelection {
                    scaledPoster(in: size)
                } else {
                    emptySelectionPlaceholder
                }
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity)

            previewHint
        }
    }

    @ViewBuilder
    private var previewHint: some View {
        if composer.layoutOverflows {
            Label("这段词装不下了，换一种画幅或去掉几句", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        } else if composer.hasSelection {
            Text("已选 \(composer.selection.count) 句")
                .font(.caption)
                .foregroundStyle(Color(uiColor: AppColor.secondaryText))
        }
    }

    /// 预览框的实际尺寸：先按可用宽度等比缩，再受最大高度约束。
    ///
    /// 刚出现时宽度可能还是 0，给一个下限，免得算出 0 尺寸的预览框。
    private func previewSize(availableWidth: CGFloat) -> CGSize {
        let posterWidth = CGFloat(composer.canvas.pixelWidth)
        let posterHeight = CGFloat(composer.canvas.pixelHeight)
        let width = max(availableWidth, 120)
        let scale = min(
            width / posterWidth,
            LyricsPosterMetrics.previewMaximumHeight / posterHeight
        )
        return CGSize(width: posterWidth * scale, height: posterHeight * scale)
    }

    /// 把 1080 宽的海报整体缩进预览框。
    ///
    /// 缩放锚点必须和外层 `frame` 的对齐方式配套：`scaleEffect` 不改变布局尺寸，
    /// 海报仍按原始尺寸居中摆进预览框（左上角落在框外很远），这时若用 `.topLeading`
    /// 作锚点，缩放后的画面整个留在可见区域之外 —— 看上去就是"一片空白"。
    private func scaledPoster(in size: CGSize) -> some View {
        let posterWidth = CGFloat(composer.canvas.pixelWidth)
        let posterHeight = CGFloat(composer.canvas.pixelHeight)
        // 宽高都不许越界：预览框还受最大高度约束，只按宽度算会在竖版画幅上溢出。
        let scale = min(size.width / posterWidth, size.height / posterHeight)
        return posterContent
            .frame(width: posterWidth, height: posterHeight)
            .scaleEffect(scale)
            // 收到缩放后的真实尺寸上，圆角和投影才贴着海报边缘。
            .frame(width: posterWidth * scale, height: posterHeight * scale)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color(uiColor: AppColor.shadow).opacity(0.25), radius: 18, y: 8)
    }

    /// 预览里画什么：动态时 20fps 循环演，静态时只画最后一刻。
    ///
    /// 20fps 足够演逐句浮现 —— 按屏幕刷新率重画会让那几处上百点半径的模糊一直重算。
    @ViewBuilder
    private var posterContent: some View {
        if canExportMotion {
            TimelineView(.periodic(from: previewEpoch, by: 1.0 / 20.0)) { timeline in
                let plan = composer.motionPlan
                // 一次演完停半秒再来，跟相册里长按实况的观感一致。
                let elapsed = timeline.date.timeIntervalSince(previewEpoch)
                let cycle = plan.duration + 0.6
                let time = cycle > 0 ? elapsed.truncatingRemainder(dividingBy: cycle) : 0
                composer.preview(at: min(time, plan.duration), isMotion: true)
            }
        } else {
            composer.preview(at: 0, isMotion: false)
        }
    }

    /// 动态预览与动态导出共用的判据：开关开着，且当前风格真的能动。
    private var canExportMotion: Bool {
        composer.prefersMotion && (composer.descriptor?.supportsMotion ?? false)
    }

    /// 当前风格支不支持动态 —— 不支持时"实况照片"开关置灰。
    private var motionSupported: Bool {
        composer.descriptor?.supportsMotion ?? false
    }

    private var emptySelectionPlaceholder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(uiColor: AppColor.surface))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "text.quote")
                        .font(.largeTitle)
                    Text("还没选歌词")
                        .font(.callout)
                }
                .foregroundStyle(Color(uiColor: AppColor.secondaryText))
            }
    }

    // MARK: - 风格 / 画幅

    private var styleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("风格")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(composer.availableDescriptors) { descriptor in
                        styleChip(descriptor)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color(uiColor: AppColor.secondaryText))
    }

    private func styleChip(_ descriptor: LyricsPosterStyleDescriptor) -> some View {
        let isSelected = descriptor.id == composer.styleID
        let tint = Color(uiColor: AppColor.accent)
        return Button {
            composer.select(style: descriptor)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: descriptor.symbolName)
                    .font(.title3)
                Text(descriptor.name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .frame(width: 78, height: 66)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.18) : Color(uiColor: AppColor.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? tint : Color.clear, lineWidth: 2)
            )
            .foregroundStyle(isSelected ? tint : Color(uiColor: AppColor.title))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// 画幅分段。选中那一刻顺手存进设置（`setCanvas` 干的），这一页不自己存。
    private var canvasRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("画幅")

            Picker("画幅", selection: canvasBinding) {
                ForEach(composer.supportedCanvases, id: \.self) { canvas in
                    Text(canvas.title).tag(canvas)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var canvasBinding: Binding<LyricsPosterCanvas> {
        Binding(
            get: { composer.canvas },
            set: { composer.setCanvas($0) }
        )
    }

    // MARK: - 选项

    private var options: some View {
        VStack(spacing: 0) {
            Toggle(isOn: motionBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实况照片")
                    Text("存到相册后长按可看动效")
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: AppColor.secondaryText))
                }
            }
            .disabled(!motionSupported)
            .padding(.vertical, 10)

            Divider()

            Toggle(isOn: Binding(
                get: { composer.showsCredit },
                set: { composer.setShowsCredit($0) }
            )) {
                Text("显示署名")
            }
            .padding(.vertical, 10)
        }
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: AppColor.surface))
        )
    }

    /// 开关的"显示值"要连风格一起判：风格不支持动态时它显示成关，免得开着一个
    /// 存不出来的东西。
    private var motionBinding: Binding<Bool> {
        Binding(
            get: { composer.prefersMotion && motionSupported },
            set: {
                composer.setPrefersMotion($0)
                previewEpoch = Date()
            }
        )
    }

    // MARK: - 工具栏与底部条

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("取消") {
                exportTask?.cancel()
                onDismiss()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                isPickingLines = true
            } label: {
                Label("选择歌词", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if composer.isExporting {
                ProgressView(value: composer.exportProgress) {
                    Text("正在导出动态海报")
                        .font(.caption)
                }
                .progressViewStyle(.linear)
            } else if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            HStack(spacing: 12) {
                Button {
                    saveToPhotos()
                } label: {
                    actionLabel("存到相册", symbol: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)

                Button {
                    share()
                } label: {
                    actionLabel("分享", symbol: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
            .controlSize(.large)
            .disabled(!composer.hasSelection || composer.isExporting)
            .confirmationDialog("分享", isPresented: $isShareChoicePresented, titleVisibility: .hidden) {
                Button("分享图片") { shareStill() }
                Button("分享实况视频") { shareMotion() }
                Button("取消", role: .cancel) {}
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func actionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    // MARK: - 导出

    /// 存相册。动态时导出实况照片、静态时导出 PNG —— 两条路都等系统写盘。
    private func saveToPhotos() {
        let motion = canExportMotion
        runExport {
            if motion {
                let bundle = try await composer.exportLivePhoto()
                try await LyricsPosterPhotoLibrary.save(livePhoto: bundle)
            } else {
                let url = try composer.exportStillImage()
                try await LyricsPosterPhotoLibrary.save(image: url)
            }
        } completion: {
            statusMessage = motion ? "已存实况照片" : "已存到相册"
            // 敢吞：只是"两秒后把提示收起来"；页面已经关掉的话（任务被取消）就没有什么要收的。
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            statusMessage = nil
        }
    }

    /// 分享。动态时先问一句要图片还是实况视频 —— 实况照片没法直接进系统分享面板。
    private func share() {
        if canExportMotion {
            isShareChoicePresented = true
        } else {
            shareStill()
        }
    }

    /// 分享静态 PNG。文件交给宿主去弹系统面板 —— iPad 上的气泡要锚点，那是 UIKit 的事。
    private func shareStill() {
        runExport {
            onShare(try composer.exportStillImage())
        } completion: {}
    }

    /// 分享动态视频。实况照片的两半是给相册用的，出了相册就是一段 MOV。
    private func shareMotion() {
        runExport {
            let bundle = try await composer.exportLivePhoto()
            onShare(bundle.videoURL)
        } completion: {}
    }

    /// 存相册这一路的统一收口：取消、报错、任务生命周期只在这儿处理一次。
    private func runExport(
        _ work: @escaping @MainActor () async throws -> Void,
        completion: @escaping @MainActor () async -> Void
    ) {
        exportTask?.cancel()
        statusMessage = nil
        exportTask = Task { @MainActor in
            do {
                try await work()
                guard !Task.isCancelled else { return }
                await completion()
            } catch is CancellationError {
                // 用户把页面关了，不需要弹错误。
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
