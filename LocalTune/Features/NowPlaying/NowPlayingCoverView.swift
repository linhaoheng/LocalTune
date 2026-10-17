import SnapKit
import UIKit

/// 播放页的**大封面** —— 这一页唯一会伸缩的一块。
///
/// ## 它自己是"盒子"，里面那个框才是封面
///
/// 版式上这一块是**弹性块**：上面顶着音质条、下面离信息行一点点，中间剩多少都是它的。
/// 封面本身**保持图的宽高比**、取"盒子里能放下的最大那个"。
/// 当前 / 预览各是**一层视图**（切歌 transform 作用在这一层上），框是它的直接子视图：
///
/// ```
/// NowPlayingCoverView          透明、被外层约束撑成弹性块（它自己不画、不取图）
///   ├── current                当前这一层（CoverArtworkSlot）
///   │     └── shadowView       图的宽高比、圆角、阴影 —— 取图在这一层的 layout
///   │           └── artworkView
///   └── preview                预览这一层（另一侧滑进来）
///         └── shadowView …
/// ```
///
/// 🔴 **尺寸**（`layoutArt` 那一段）：
/// 先取方框 `边 = min(min(盒宽, 盒高) − 2×让位, 600)`，图不是正方形就**按比例缩短一边**。
/// 解法仍是约束，不是手算 frame。
///
/// 🔴 **取图跟框同一层**：框是 `CoverArtworkSlot` 的直接子视图，尺寸变了由它自己的
/// `layoutSubviews` 去取 —— 不能站在弹性块上猜孙视图的 bounds。
///
/// 左右拖切歌的位移 / 松手口令在 `NowPlayingCoverSwipe`，不进这一块。
final class NowPlayingCoverView: UIView {

    /// 一侧能切时的预览。`artworkPath == nil` 仍是「有邻居、只是没图」。
    struct Neighbor: Equatable {
        var artworkPath: String?
    }

    // MARK: - 依赖

    /// 取封面的动作，由装配层给（`AppArtwork.image`）。**没人给就只画占位**，照样能跑。
    var artworkProvider: ArtworkProvider? {
        didSet {
            current.artworkProvider = artworkProvider
            preview.artworkProvider = artworkProvider
        }
    }

    /// 封面滑出切到上一首 / 下一首。页面接到再转给 VM。
    var onSwipePrevious: (() -> Void)?
    var onSwipeNext: (() -> Void)?

    // MARK: - 私有

    private let current = CoverArtworkSlot()
    private let preview = CoverArtworkSlot()
    private let swipe = NowPlayingCoverSwipe()

    /// 现在画的是哪一个封面文件。⚠️ **初值是 `nil`、占位也画好了**。
    private var artworkPath: String?
    private var previewPath: String?
    private var previousNeighbor: Neighbor?
    private var nextNeighbor: Neighbor?

    // MARK: - 建立

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildSubviews()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 对外

    /// 换封面和两侧预览路径。**当前路径没变就不重取当前图** —— 底下的订阅一秒能被叫到十几次。
    ///
    /// 提交滑出那 0.25 秒里不改当前图，避免把正在滑走的那一层掐掉。
    func show(artworkPath: String?, previous: Neighbor?, next: Neighbor?) {
        previousNeighbor = previous
        nextNeighbor = next
        swipe.hasPrevious = previous != nil
        swipe.hasNext = next != nil
        guard !swipe.isCommitting else { return }
        guard artworkPath != self.artworkPath else { return }
        self.artworkPath = artworkPath
        current.apply(path: artworkPath)
    }

    /// 播放态 —— **暂停缩、播放放**。
    ///
    /// 🔴 **不能塞进上面那个 `show`**：它开头 `guard artworkPath != self.artworkPath` 会把
    /// 「只播停、没换歌」的推送整条吞掉 ⇒ 播停永远不缩。所以页面**单独喊这一句**。
    /// 🔴 **当前 / 预览两层都要设** —— 只设一层，切歌提交后 `adopt` 过来的那层倍数就是旧的。
    func setPlaying(_ playing: Bool) {
        current.setPlaying(playing)
        preview.setPlaying(playing)
    }

    // MARK: - 装配

    private func buildSubviews() {
        backgroundColor = .clear
        preview.alpha = 0
        // 这一块是链上唯一的弹性块：纵向让得出去。抗压缩若跟信息行同档（750），
        // 框里「撑宽 + 方图比例」会要容器至少和列一样高，把副标题和时间挤没。
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        addSubview(current)
        addSubview(preview)
        current.snp.makeConstraints { $0.edges.equalToSuperview() }
        preview.snp.makeConstraints { $0.edges.equalToSuperview() }

        swipe.attach(host: self, current: current, preview: preview)
        swipe.onPreviewDirection = { [weak self] toPrevious in
            self?.applyPreview(toPrevious: toPrevious)
        }
        swipe.onCommitted = { [weak self] toPrevious in
            self?.finishCommit(toPrevious: toPrevious)
        }
    }

    /// 竖屏让位 30、手机横屏 16。两层一起换，各层自己 remake 框的上限。
    func applyLayoutKind(_ kind: NowPlayingLayoutKind) {
        let inset = kind.coverInset
        current.setCoverInset(inset)
        preview.setCoverInset(inset)
    }

    /// 过死区换方向时填预览层。
    private func applyPreview(toPrevious: Bool) {
        let neighbor = toPrevious ? previousNeighbor : nextNeighbor
        previewPath = neighbor?.artworkPath
        preview.apply(path: neighbor?.artworkPath)
    }

    private func finishCommit(toPrevious: Bool) {
        current.adopt(from: preview)
        artworkPath = previewPath
        if toPrevious {
            onSwipePrevious?()
        } else {
            onSwipeNext?()
        }
    }
}

// MARK: - 一层封面（当前 / 预览各一份）

/// 一整层：透明底板 + 阴影框 + 图。切歌 transform 作用在这一层上，框是直接子视图。
///
/// 取图在这里：`layoutSubviews` 里 `super` 回来框的 bounds 才是真的
/// （跟第三刀之前 CoverView 直接管 `shadowView` 同一件事）。
private final class CoverArtworkSlot: UIView {

    var artworkProvider: ArtworkProvider?

    private let shadowView = UIView()
    private let artworkView = UIImageView()

    private var aspectConstraint: Constraint?
    private(set) var aspectRatio: CGFloat = 1
    private var lastArtworkSize: CGSize = .zero
    private var appliedPath: String?
    private var hasApplied = false

    /// 播放态 —— 暂停时 `shadowView` 整层缩到 `nowPlayingCoverPausedScale`。
    ///
    /// ⚠️ 缩放**只作用在 `shadowView` 上**，不碰这一层（slot）自己的 `transform`。
    private var isPlaying = true

    /// 播停**第一次**进来不带动画 —— 进页面时该多大就多大（从 0.835 弹到 1.0 是错的）。
    private var hasSetPlaying = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildSubviews()
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    private var inset: CGFloat = AppMetrics.nowPlayingCoverInset

    func setCoverInset(_ inset: CGFloat) {
        guard self.inset != inset else { return }
        self.inset = inset
        applyBoxConstraints()
    }

    func apply(path: String?) {
        appliedPath = path
        hasApplied = true
        render()
    }

    func adopt(from other: CoverArtworkSlot) {
        artworkView.image = other.artworkView.image
        artworkView.contentMode = other.artworkView.contentMode
        artworkView.tintColor = other.artworkView.tintColor
        appliedPath = other.appliedPath
        hasApplied = true
        setAspectRatio(other.aspectRatio)
    }

    // MARK: - 随播放态缩放

    /// 暂停缩到 `nowPlayingCoverPausedScale`、播放回到 `1`。**首帧不带动画**。
    ///
    /// 🔴 缩放打在自己的 `shadowView` 上 —— **不碰这一层（slot）的 `transform`**：
    /// 那是 `NowPlayingCoverSwipe` 的地盘（滑动写位移、复位写 `.identity`），
    /// 缩放放同一层会**互相抹掉**（拖到一半播停一变，位移没了；提交复位时缩放被抹成 1）。
    func setPlaying(_ playing: Bool) {
        let isFirst = !hasSetPlaying
        hasSetPlaying = true
        guard playing != isPlaying || isFirst else { return }
        isPlaying = playing
        applyScale(animated: !isFirst)
    }

    private func applyScale(animated: Bool) {
        let changes = {
            self.shadowView.transform = CGAffineTransform(scaleX: self.scale, y: self.scale)
            // 圆角反补：实测两态**视觉半径恒定** ⇒ 层被缩放多少，半径就放大多少。
            self.artworkView.layer.cornerRadius = self.displayCornerRadius
            self.updateShadowPath()
        }
        guard animated else {
            changes()
            return
        }
        UIView.animate(
            withDuration: isPlaying
                ? AppMetrics.nowPlayingCoverExpandDuration
                : AppMetrics.nowPlayingCoverShrinkDuration,
            delay: 0,
            usingSpringWithDamping: isPlaying
                ? AppMetrics.nowPlayingCoverExpandDamping
                : AppMetrics.nowPlayingCoverShrinkDamping,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: changes
        )
    }

    /// 当前倍数 —— 播放 `1` / 暂停 `nowPlayingCoverPausedScale`。
    private var scale: CGFloat {
        isPlaying ? 1 : AppMetrics.nowPlayingCoverPausedScale
    }

    /// 反补后的圆角 —— 缩放不吃掉观感半径。
    private var displayCornerRadius: CGFloat {
        AppMetrics.nowPlayingCoverCornerRadius / scale
    }

    /// 重建阴影路径。⚠️ 路径按 `bounds` 设，而 `transform` 不改 `bounds` ——
    /// 尺寸变的那次仍由 `layoutSubviews` 再调一遍。
    private func updateShadowPath() {
        shadowView.layer.shadowPath = UIBezierPath(
            roundedRect: shadowView.bounds,
            cornerRadius: displayCornerRadius
        ).cgPath
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateShadowPath()
        let size = shadowView.bounds.size
        guard size != lastArtworkSize else { return }
        lastArtworkSize = size
        guard hasApplied else { return }
        render()
    }

    /// 换到别的屏幕上倍数可能变 —— 图要按新的倍数重取一遍。
    ///
    /// ⚠️ 光靠 `layoutSubviews` 不够：倍数变了但尺寸没变，那儿的"尺寸变了才重取"就挡住了。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        render()
    }

    private func buildSubviews() {
        backgroundColor = .clear

        shadowView.layer.masksToBounds = false
        shadowView.layer.cornerRadius = AppMetrics.nowPlayingCoverCornerRadius
        shadowView.layer.cornerCurve = .continuous
        shadowView.layer.shadowColor = AppColor.shadow.cgColor
        shadowView.layer.shadowOpacity = AppMetrics.nowPlayingCoverShadowOpacity
        shadowView.layer.shadowRadius = AppMetrics.nowPlayingCoverShadowRadius
        shadowView.layer.shadowOffset = AppMetrics.nowPlayingCoverShadowOffset

        artworkView.contentMode = .center
        // 🔴 占位用**浮层色族**（`overlay*`）—— 这一页是"常暗浮层"，底永远是深色。
        artworkView.tintColor = AppColor.overlayTint
        artworkView.backgroundColor = AppColor.overlayFillSubtle
        artworkView.layer.cornerRadius = AppMetrics.nowPlayingCoverCornerRadius
        artworkView.layer.cornerCurve = .continuous
        artworkView.clipsToBounds = true
        artworkView.isUserInteractionEnabled = false
        artworkView.image = CoverArtworkSlot.placeholderSymbol()
        // 框多大由下面的上限约束解；图的像素固有尺寸不能回头去撑容器。
        for piece in [self, shadowView, artworkView] {
            piece.setContentHuggingPriority(.defaultLow, for: .vertical)
            piece.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
        artworkView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        artworkView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(shadowView)
        shadowView.addSubview(artworkView)
        applyBoxConstraints()
        artworkView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func applyBoxConstraints() {
        let inset = inset
        let maxSide = AppMetrics.nowPlayingCoverMaxSide
        shadowView.snp.remakeConstraints { make in
            make.center.equalToSuperview()
            make.width.lessThanOrEqualToSuperview().offset(-inset * 2)
            make.width.lessThanOrEqualTo(snp.height).offset(-inset * 2)
            make.height.lessThanOrEqualToSuperview().offset(-inset * 2)
            make.height.lessThanOrEqualTo(snp.width).offset(-inset * 2)
            make.width.lessThanOrEqualTo(maxSide)
            make.height.lessThanOrEqualTo(maxSide)
            // 只能拿宽去撑：再锁「高 = 容器高 − 2×inset」会把信息行拉高。
            // 750 只在槽内把框撑到上限；槽矮时这条自己破。封面容器纵向是 low，
            // 信息行 / 进度是 required，撑宽打不赢它们。
            make.width.equalToSuperview().offset(-inset * 2).priority(.high)
        }
        lockAspectRatio()
    }

    private func render() {
        let size = shadowView.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        if let image = artworkProvider?(appliedPath, size, traitCollection.displayScale) {
            artworkView.image = image
            artworkView.contentMode = .scaleAspectFill
            setAspectRatio(image.size.height > 0 ? image.size.width / image.size.height : 1)
            return
        }

        artworkView.image = CoverArtworkSlot.placeholderSymbol()
        artworkView.contentMode = .center
        setAspectRatio(1)
    }

    private func setAspectRatio(_ ratio: CGFloat) {
        guard ratio != aspectRatio else { return }
        aspectRatio = ratio
        lockAspectRatio()
    }

    private func lockAspectRatio() {
        aspectConstraint?.deactivate()
        shadowView.snp.makeConstraints { make in
            aspectConstraint = make.width.equalTo(shadowView.snp.height)
                .multipliedBy(aspectRatio).constraint
        }
    }

    private static func placeholderSymbol() -> UIImage? {
        UIImage(systemName: "music.note")
    }
}
