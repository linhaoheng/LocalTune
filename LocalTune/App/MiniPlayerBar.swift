import MarqueeLabel
import SnapKit
import UIKit

/// 底部那条迷你播放条里的**一行** —— 封面 + 歌名 + 两个键；封面区可左右滑切歌。
/// 顶上另有一条 1pt 进度，**不进 `Content`**。
///
/// ⚠️ **只有歌名一行，没有艺人** —— 条子只有 60 高，一行塞两样信息会挤。
///
/// **纯显示**：它不认识播放器、不认识库 —— 只认一个 `Content`、
/// 一个 `Progress`、一个取封面的动作和四个回调，**全从 `init` 给**。
///
/// ## 通栏，不是浮动卡片
///
/// 它**没有自己的背景** —— 玻璃由底下那一整块（`MiniBarNavController` 里那层材质）提供。
///
/// ## 几何
///
/// 整条 **60**；封面 **40**（圆角 8）；两个键宽 **40**、高撑满；
/// 滑动区 = 封面+标题（不含右侧两键）。数字全在 `AppMetrics`。
final class MiniPlayerBar: UIView {

    // MARK: - 内容

    /// 条子上要显示的东西。
    ///
    /// ⚠️ 它是**值**、可以比较（`Equatable`）—— 「内容没变就别重画」是白拿的。
    struct Content: Equatable {

        /// 「未在播放」文案 —— 空歌标题唯一出处。
        static let notPlayingTitle = "未在播放"

        /// 一侧滑动预览（封面 + 标题）。`nil` ＝ 这一侧不能切，松手回弹。
        struct Preview: Equatable {
            var title: String
            var artworkPath: String?
        }

        var title: String
        /// 播放会话是否活跃（在装 / 在播）= 显示暂停键，否则显示播放键。
        var isPlaybackActive: Bool
        /// 封面文件名；没图传 `nil`。
        var artworkPath: String?
        /// 右滑预览（上一首）；没有就不提交上一首。
        var previousPreview: Preview?
        /// 左滑预览（下一首）；没有就不提交下一首。
        var nextPreview: Preview?

        /// 没有歌在播时的样子 —— 条子照样在，写着「未在播放」。
        /// 点条子仍会回调；打不打开播放页由 `AppRouter.presentNowPlaying` 门闩决定。
        static let notPlaying = Content(
            title: notPlayingTitle,
            isPlaybackActive: false,
            artworkPath: nil,
            previousPreview: nil,
            nextPreview: nil
        )
    }

    /// 顶上那条进度。**不进 `Content`** —— 10Hz 推 Content 会掐 Marquee。
    ///
    /// ⚠️ 它是**值**、可以比较：流上 `distinctUntilChanged` 才推得出类型，不用手写比较闭包。
    struct Progress: Equatable {
        var fraction: Float
        var visible: Bool

        static let hidden = Progress(fraction: 0, visible: false)
    }

    // MARK: - 依赖

    private let artworkProvider: ArtworkProvider
    private let onTap: () -> Void
    private let onPlayPause: () -> Void
    private let onNext: () -> Void
    private let onPrevious: () -> Void

    // MARK: - 私有

    private var content: Content = .notPlaying
    private var progress: Progress = .hidden

    /// 提交切歌动画进行中 —— 这段时间 `show` 只改播放键，不碰封面/标题 transform。
    ///
    /// ⚠️ 不要「等 currentTrack 晚到」那种补丁：我们的 `start` 会立刻改 `PlayerState`；
    /// 这里只防 0.2s 滑出动画被中途 `show` 掐掉。
    private var isCommittingSwipe = false

    private enum SwipeDirection {
        case previous
        case next
        case none
    }

    private var currentSwipeDirection: SwipeDirection = .none
    private var initialSwipeX: CGFloat = 0

    private let swipeContentView = UIView()
    private let artworkView = UIImageView()
    private let titleLabel = MarqueeLabel()
    private let previewArtworkView = UIImageView()
    private let previewTitleLabel = MarqueeLabel()
    private let playPauseButton = PressScaleButton(icon: nil)
    private let nextButton = PressScaleButton(icon: nil)
    private let progressView = UIProgressView(progressViewStyle: .default)

    // MARK: - 建立

    /// 🔴 **要用的东西全从这个 `init` 进**。
    init(
        artworkProvider: @escaping ArtworkProvider,
        onTap: @escaping () -> Void,
        onPlayPause: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onPrevious: @escaping () -> Void
    ) {
        self.artworkProvider = artworkProvider
        self.onTap = onTap
        self.onPlayPause = onPlayPause
        self.onNext = onNext
        self.onPrevious = onPrevious
        super.init(frame: .zero)
        buildSubviews()
        wireActions()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 对外

    /// 顶上进度。**不进 `Content`**。值没变就什么都不做。
    func show(_ progress: Progress) {
        guard progress != self.progress else { return }
        self.progress = progress
        if progress.visible {
            progressView.setProgress(progress.fraction, animated: false)
            progressView.isHidden = false
        } else {
            progressView.isHidden = true
            progressView.setProgress(0, animated: false)
        }
    }

    /// 换内容。**值没变就什么都不做**。
    func show(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        if isCommittingSwipe {
            // 动画中只改播放键 —— 封面/标题正被手势带着走。
            applyPlayPause(content.isPlaybackActive)
            return
        }
        apply(content)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        apply(content)
    }

    // MARK: - 装配

    private func buildSubviews() {
        snp.makeConstraints { make in
            make.height.equalTo(AppMetrics.miniPlayerBarHeight)
        }

        nextButton.icon = Self.symbol("forward.fill")
        nextButton.accessibilityLabel = "下一首"
        playPauseButton.accessibilityLabel = "播放"

        configureCover(artworkView)
        configureCover(previewArtworkView)
        previewArtworkView.alpha = 0

        configureMarquee(titleLabel)
        configureMarquee(previewTitleLabel)
        previewTitleLabel.alpha = 0

        addSubview(swipeContentView)
        addSubview(playPauseButton)
        addSubview(nextButton)
        addSubview(progressView)

        swipeContentView.clipsToBounds = true
        swipeContentView.addSubview(artworkView)
        swipeContentView.addSubview(titleLabel)
        swipeContentView.addSubview(previewArtworkView)
        swipeContentView.addSubview(previewTitleLabel)

        nextButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(AppMetrics.miniPlayerNextButtonTrailingInset)
            make.top.bottom.equalToSuperview()
            make.width.equalTo(AppMetrics.miniPlayerButtonWidth)
        }

        playPauseButton.snp.makeConstraints { make in
            make.trailing.equalTo(nextButton.snp.leading).offset(-AppMetrics.s10)
            make.top.bottom.equalToSuperview()
            make.width.equalTo(AppMetrics.miniPlayerButtonWidth)
        }

        // 滑动区停在播放键左边 —— 两键不进滑动手势。
        swipeContentView.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.trailing.equalTo(playPauseButton.snp.leading).offset(-AppMetrics.s15)
        }

        artworkView.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(AppMetrics.s15)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(AppMetrics.miniPlayerArtworkSize)
        }

        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(artworkView.snp.trailing).offset(AppMetrics.s12)
            make.centerY.equalToSuperview()
            make.trailing.equalToSuperview()
        }

        previewArtworkView.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(AppMetrics.s15)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(AppMetrics.miniPlayerArtworkSize)
        }

        previewTitleLabel.snp.makeConstraints { make in
            make.leading.equalTo(previewArtworkView.snp.trailing).offset(AppMetrics.s12)
            make.centerY.equalToSuperview()
            make.trailing.equalToSuperview()
        }

        progressView.isUserInteractionEnabled = false
        progressView.isHidden = true
        applyProgressColors()
        progressView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(AppMetrics.miniPlayerProgressHeight)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        applyProgressColors()
    }

    /// 走条强调色叠 α；轨道表面色。不用笼统 `tintColor`，深浅各自解析后再叠透明度。
    private func applyProgressColors() {
        progressView.progressTintColor = UIColor { trait in
            AppColor.accent.resolvedColor(with: trait)
                .withAlphaComponent(AppMetrics.miniPlayerProgressFillAlpha)
        }
        progressView.trackTintColor = AppColor.surface
    }

    private func configureCover(_ view: UIImageView) {
        view.contentMode = .center
        view.tintColor = AppColor.subtitle
        // 空歌底用 `surface`（slate3）。
        view.backgroundColor = AppColor.surface
        view.layer.cornerRadius = AppMetrics.miniPlayerArtworkCornerRadius
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
    }

    /// 迷你条歌名跑马灯 —— **不设**播放页那档尾缓冲和开滚停顿。
    private func configureMarquee(_ label: MarqueeLabel) {
        label.font = AppFont.miniPlayerTitle
        label.textColor = AppColor.title
        label.isUserInteractionEnabled = false
        label.fadeLength = AppMetrics.marqueeFadeLength
        label.speed = .rate(AppMetrics.marqueeScrollRate)
    }

    private func wireActions() {
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        swipeContentView.addGestureRecognizer(pan)

        // ⚠️ **不用** `tap.require(toFail: pan)` —— 那样会拖慢每次点开播放页。
        // 轻点时 pan 认不出位移 ⇒ 失败，tap 照常触发。
        let tap = UITapGestureRecognizer(target: self, action: #selector(barTapped))
        tap.delegate = self
        swipeContentView.addGestureRecognizer(tap)
    }

    // MARK: - 应用内容

    private func apply(_ content: Content) {
        // ⚠️ 标题真变了才写 —— MarqueeLabel 每次 setText 都会重置滚动。
        if titleLabel.text != content.title {
            titleLabel.text = content.title
        }
        applyPlayPause(content.isPlaybackActive)
        applyArtwork(content.artworkPath, to: artworkView)
    }

    private func applyPlayPause(_ isPlaybackActive: Bool) {
        playPauseButton.icon = Self.symbol(isPlaybackActive ? "pause.fill" : "play.fill")
        playPauseButton.accessibilityLabel = isPlaybackActive ? "暂停" : "播放"
    }

    private func applyArtwork(_ artworkPath: String?, to imageView: UIImageView) {
        let pointSize = CGSize(
            width: AppMetrics.miniPlayerArtworkSize,
            height: AppMetrics.miniPlayerArtworkSize
        )
        guard let image = artworkProvider(artworkPath, pointSize, traitCollection.displayScale) else {
            imageView.image = Self.symbol("music.note")
            imageView.contentMode = .center
            imageView.tintColor = AppColor.subtitle
            return
        }
        imageView.image = image
        imageView.contentMode = .scaleAspectFill
        imageView.tintColor = nil
    }

    private func applyPreview(_ preview: Content.Preview?) {
        let title = preview?.title ?? Content.notPlayingTitle
        // ⚠️ 标题真变了才写 —— 同 `apply`，避免方向来回切时反复掐滚动。
        if previewTitleLabel.text != title {
            previewTitleLabel.text = title
        }
        applyArtwork(preview?.artworkPath, to: previewArtworkView)
    }

    private static func symbol(_ name: String) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: AppMetrics.miniPlayerButtonIconPointSize,
                weight: .medium
            )
        )
    }

    // MARK: - 滑动

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let width = swipeContentView.bounds.width
        guard width > 0, !isCommittingSwipe else { return }

        switch gesture.state {
        case .began:
            initialSwipeX = artworkView.transform.tx
            currentSwipeDirection = .none

        case .changed:
            var offset = gesture.translation(in: swipeContentView).x + initialSwipeX
            offset = min(max(offset, -width), width)
            let direction: SwipeDirection = offset > 0 ? .previous : .next
            let progress = abs(offset)
            if currentSwipeDirection != direction,
               progress > AppMetrics.miniPlayerSwipeDirectionDeadZone {
                currentSwipeDirection = direction
                let preview = direction == .previous
                    ? content.previousPreview
                    : content.nextPreview
                applyPreview(preview)
            }
            applySwipeTransforms(offset: offset, width: width)

        case .ended:
            finishPan(
                translationX: artworkView.transform.tx,
                velocityX: gesture.velocity(in: swipeContentView).x,
                width: width
            )

        case .cancelled:
            // 🔴 系统取消 ≠ 用户松手提交 —— cancelled 当 ended 会误切歌。
            cancelSwipe(width: width)

        default:
            break
        }
    }

    private func finishPan(translationX: CGFloat, velocityX: CGFloat, width: CGFloat) {
        let commit = horizontalSwipeCommit(
            translationX: translationX,
            velocityX: velocityX,
            commitDistance: AppMetrics.miniPlayerSwipeCommitDistance,
            commitVelocity: AppMetrics.miniPlayerSwipeCommitVelocity
        )
        let action = horizontalSwipeAction(
            commit: commit,
            hasPrevious: content.previousPreview != nil,
            hasNext: content.nextPreview != nil
        )
        switch action {
        case .playPrevious:
            commitSwipe(toPrevious: true, width: width)
        case .playNext:
            commitSwipe(toPrevious: false, width: width)
        case .springBack:
            cancelSwipe(width: width)
        }
    }

    private func applySwipeTransforms(offset: CGFloat, width: CGFloat) {
        let currentTransform = CGAffineTransform(translationX: offset, y: 0)
        artworkView.transform = currentTransform
        titleLabel.transform = currentTransform

        let previewBase = offset <= 0 ? width : -width
        let previewTransform = CGAffineTransform(translationX: offset + previewBase, y: 0)
        previewArtworkView.transform = previewTransform
        previewTitleLabel.transform = previewTransform

        let progress = min(abs(offset) / width, 1)
        let currentAlpha = 1 - progress * AppMetrics.miniPlayerSwipeCurrentFadeFactor
        artworkView.alpha = currentAlpha
        titleLabel.alpha = currentAlpha
        let previewAlpha = min(progress * AppMetrics.miniPlayerSwipePreviewRiseFactor, 1)
        previewArtworkView.alpha = previewAlpha
        previewTitleLabel.alpha = previewAlpha
    }

    private func commitSwipe(toPrevious: Bool, width: CGFloat) {
        isCommittingSwipe = true
        // 🔴 按**提交方向**重填预览 —— 不能沿用滑动过程中最后一次 applyPreview。
        // 反例：右滑过死区看到上一首 → 滑回原点附近（未再过死区换预览）→ 向左快拂
        // 提交下一首时，preview 视图里还挂着上一首；或不曾过死区则是空白。
        applyPreview(toPrevious ? content.previousPreview : content.nextPreview)
        let exitX = toPrevious ? width : -width
        UIView.animate(
            withDuration: AppMetrics.miniPlayerSwipeCommitDuration,
            delay: 0,
            options: .beginFromCurrentState,
            animations: {
                self.artworkView.transform = CGAffineTransform(translationX: exitX, y: 0)
                self.titleLabel.transform = CGAffineTransform(translationX: exitX, y: 0)
                self.artworkView.alpha = 0
                self.titleLabel.alpha = 0
                self.previewArtworkView.transform = .identity
                self.previewTitleLabel.transform = .identity
                self.previewArtworkView.alpha = 1
                self.previewTitleLabel.alpha = 1
            },
            completion: { _ in
                if toPrevious {
                    self.onPrevious()
                } else {
                    self.onNext()
                }
                // 乐观承接预览，避免切歌后封面闪一帧旧图；随后 state 流会用真 Content 对齐。
                if let image = self.previewArtworkView.image {
                    self.artworkView.image = image
                    self.artworkView.contentMode = self.previewArtworkView.contentMode
                    self.artworkView.tintColor = self.previewArtworkView.tintColor
                }
                self.titleLabel.text = self.previewTitleLabel.text
                self.resetSwipeVisuals()
                self.isCommittingSwipe = false
                // 用最新 content 的播放态（动画期间可能已变）；封面标题若 state 已到会再走 show。
                self.applyPlayPause(self.content.isPlaybackActive)
            }
        )
    }

    private func cancelSwipe(width: CGFloat) {
        let previewExit: CGFloat = currentSwipeDirection == .previous ? -width : width
        UIView.animate(
            withDuration: AppMetrics.miniPlayerSwipeSpringDuration,
            delay: 0,
            usingSpringWithDamping: AppMetrics.miniPlayerSwipeSpringDamping,
            initialSpringVelocity: AppMetrics.miniPlayerSwipeSpringVelocity,
            options: [],
            animations: {
                self.artworkView.transform = .identity
                self.titleLabel.transform = .identity
                self.artworkView.alpha = 1
                self.titleLabel.alpha = 1
                self.previewArtworkView.transform = CGAffineTransform(translationX: previewExit, y: 0)
                self.previewTitleLabel.transform = CGAffineTransform(translationX: previewExit, y: 0)
                self.previewArtworkView.alpha = 0
                self.previewTitleLabel.alpha = 0
            },
            completion: { _ in
                self.currentSwipeDirection = .none
            }
        )
    }

    private func resetSwipeVisuals() {
        artworkView.transform = .identity
        titleLabel.transform = .identity
        artworkView.alpha = 1
        titleLabel.alpha = 1
        previewArtworkView.transform = .identity
        previewTitleLabel.transform = .identity
        previewArtworkView.alpha = 0
        previewTitleLabel.alpha = 0
        currentSwipeDirection = .none
        initialSwipeX = 0
    }

    // MARK: - 动作

    @objc private func playPauseTapped() { onPlayPause() }
    @objc private func nextTapped() { onNext() }
    @objc private func barTapped() { onTap() }
}

// MARK: - 手势

extension MiniPlayerBar: UIGestureRecognizerDelegate {

    /// 只认水平拖 —— 竖滑别带动封面。
    ///
    /// ⚠️ 必须 `override`：`UIView` 自己就有同名方法，不是协议新加的。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let v = pan.velocity(in: swipeContentView)
        return abs(v.x) > abs(v.y)
    }

    /// 落在右侧两键上的触摸不交给滑动区 tap（两键不在 swipeContentView 里，一般碰不到；
    /// 整条若以后加手势仍挡 UIControl）。
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }
}
