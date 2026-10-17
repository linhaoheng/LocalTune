import SnapKit
import UIKit

/// 歌单详情页的**表头** —— 一张大封面 ＋ 「播放」＋「随机播放」两个键。
///
/// 🔴 **它一个文字标签都没有**：歌单名走**导航栏大标题**、统计走**列表页脚** ——
/// 表头里只有封面和那两个键，跟歌单列表页那一行的分工正好对上（那一行也只画封面和名字）。
///
/// ⚠️ 它**不认识 `Playlist`**：拿到的是一个画好的封面（`PlaylistCover`）和两个回调 ——
/// "这个歌单该画哪一档"是 VM 的判断（见 `PlaylistCover` 那个构造器）。
///
/// ⚠️ **高度由内容撑**：顶 20 ＋ 封面 200 ＋ 缝 15 ＋ 键高 ＋ 底 15。
/// 挂它的人负责量一次高度写回 frame（见 `PlaylistDetailViewController+Header`）——
/// 这儿**不写"290"那种数**：那是上面这几项加出来的结果，被抄成输入就本末倒置了。
///
/// ⚠️ 底边**有发丝线**（`AppColor.separator`）：表头和下面列表之间一条分隔线；
/// 表头全页没有线是另一种做法，我们**有意不要**、把这条线留下来。
final class PlaylistDetailHeaderView: UIView {

    /// 点了「播放」。
    ///
    /// 🔴 **建这个视图的时候一起给**，不是可选的 `var`：可选回调事后接，漏了**编译不吭声**，
    /// 表现是"点了没反应"。装配在
    /// `PlaylistDetailViewController` 那个 `headerView` 属性上（它自己指回 `playAll`）。
    private let onPlayAll: () -> Void

    /// 点了「随机播放」。同上。
    private let onShuffle: () -> Void

    /// 这一块自己的尺寸。
    ///
    /// ⚠️ 只有这一个地方用 ⇒ 不进 `AppMetrics`（跟歌单行那条判据一致）。
    private enum Metrics {

        /// 封面那一格：**200 × 200**，圆角 **12**（连续曲率）。
        static let coverSide: CGFloat = 200
        static let coverCornerRadius: CGFloat = 12

        /// 封面距顶：**20**。
        static let coverTop: CGFloat = 20

        /// 左右边距 / 封面到键那条缝 / 键到这一块底边那条缝 —— **都是 15**。
        ///
        /// ⚠️ 三个位置同一个数不是巧合：这一块是**居中一列**，上下左右都是同一条边距。
        static let contentInset = AppMetrics.s15

        /// 封面底下那层投影 —— 黑、`0.18`、半径 `14`、往下偏 `6`。
        ///
        /// ⚠️ 颜色不在这儿，在 `AppColor.shadow`（纯黑），这儿只管强度。
        static let coverShadowOpacity: Float = 0.18
        static let coverShadowRadius: CGFloat = 14
        static let coverShadowOffsetY: CGFloat = 6

        /// 底边发丝线高度：**1 物理像素**（按当前屏幕倍率反推）。
        ///
        /// ⚠️ 用 `UITraitCollection.current.displayScale` 反推，而不是 `UIScreen.main.scale` ——
        /// 后者在外接屏等场景可能不准。
        static let hairlineHeight: CGFloat = 1.0 / UITraitCollection.current.displayScale
    }

    // MARK: - 零件

    /// 封面外面那一层 —— **投影挂它身上**。
    ///
    /// 🔴 不能把投影挂在封面自己身上：封面是圆角裁过的（`clipsToBounds`），
    /// 投影画在它边界外，会被那一下裁得干干净净。
    private let coverWrap = UIView()

    private let coverView = PlaylistCoverView()
    private let playButton = HeaderActionButton(title: "播放", systemImage: "play.fill")
    private let shuffleButton = HeaderActionButton(title: "随机播放", systemImage: "shuffle")

    /// 表头底边那条发丝线 —— 分隔表头和下面的列表。
    private let hairline = UIView()

    // MARK: - 建立

    init(
        artworkProvider: @escaping ArtworkProvider,
        onPlayAll: @escaping () -> Void,
        onShuffle: @escaping () -> Void
    ) {
        self.onPlayAll = onPlayAll
        self.onShuffle = onShuffle
        super.init(frame: .zero)
        coverView.artworkProvider = artworkProvider
        backgroundColor = .clear

        coverWrap.backgroundColor = .clear
        coverWrap.layer.shadowColor = AppColor.shadow.cgColor
        coverWrap.layer.shadowOpacity = Metrics.coverShadowOpacity
        coverWrap.layer.shadowRadius = Metrics.coverShadowRadius
        coverWrap.layer.shadowOffset = CGSize(width: 0, height: Metrics.coverShadowOffsetY)

        coverView.layer.cornerRadius = Metrics.coverCornerRadius
        coverView.layer.cornerCurve = .continuous

        hairline.backgroundColor = AppColor.separator
        hairline.setContentCompressionResistancePriority(.required, for: .vertical)
        hairline.setContentHuggingPriority(.required, for: .vertical)

        playButton.addAction(UIAction { [weak self] _ in self?.onPlayAll() }, for: .touchUpInside)
        shuffleButton.addAction(UIAction { [weak self] _ in self?.onShuffle() }, for: .touchUpInside)

        addSubview(coverWrap)
        coverWrap.addSubview(coverView)
        addSubview(playButton)
        addSubview(shuffleButton)
        addSubview(hairline)

        coverWrap.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(Metrics.coverTop)
            make.centerX.equalToSuperview()
            make.width.height.equalTo(Metrics.coverSide)
        }
        coverView.snp.makeConstraints { $0.edges.equalToSuperview() }

        // 🔴 两个键**等宽**、把中间填满：左 15 / 两键间 15 / 右 15。
        // 两个键的**高**不写死 —— 由它们自己的内容撑（上下 12 的内边距 ＋ 那行字），
        // 这一块的总高于是也跟着内容走（见类型顶上那段）。
        playButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(Metrics.contentInset)
            make.top.equalTo(coverWrap.snp.bottom).offset(Metrics.contentInset)
            make.bottom.equalToSuperview().offset(-Metrics.contentInset)
        }
        shuffleButton.snp.makeConstraints { make in
            make.leading.equalTo(playButton.snp.trailing).offset(Metrics.contentInset)
            make.trailing.equalToSuperview().offset(-Metrics.contentInset)
            make.centerY.equalTo(playButton)
            make.height.equalTo(playButton)
            make.width.equalTo(playButton)
        }

        hairline.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.height.equalTo(Metrics.hairlineHeight).priority(.required)
        }
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 投影的形状**每次布局重设** —— 它是个圆角矩形，路径跟着这一块的尺寸走。
        //
        // ⚠️ 用 `shadowPath` 而不是让系统照着内容算：后者每一帧都要把内容离屏画一遍再模糊，
        // 而这一块是**会跟着列表一起滚**的 —— 那是滚动时白白多出来的开销。
        //
        // ⚠️ 关掉隐式动画：`shadowPath` 一改，Core Animation 默认会补一段过渡，
        // 表现是"滚动时投影自己在动"。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        coverWrap.layer.shadowPath = UIBezierPath(
            roundedRect: coverWrap.bounds,
            cornerRadius: Metrics.coverCornerRadius
        ).cgPath
        CATransaction.commit()
    }

    // MARK: - 对外

    /// 换成要画的封面。
    func show(cover: PlaylistCover) {
        coverView.show(cover)
    }
}

// MARK: - 两个键

/// 表头上那两个键 —— 有底色、有图标和字，按下去**整块缩**。
///
/// ⚠️ **不复用 `PressScaleActionButton`**：手感（缩多少、按 / 抬时长）是同一套，但
/// **视觉参数五处全不同**（圆角 10 / 8 · 内边距 15 / 25·12 · 底色 `accent` / `surface` ·
/// 字色 `onAccent` / `accent` · 字号系统默认 / 15 粗）。硬合成一个类，就是把那个已经调好的
/// 按钮改成一个"配置袋子" —— 那正是 `PressScaleActionButton` 头上那条判据说的情形。
/// ⇒ 手感仍然只有一个出处（时长、倍数都读基类那份），**长相**各写各的。
private final class HeaderActionButton: PressableButton {

    /// 这一枚自己的尺寸。
    private enum Metrics {

        /// 圆角 **8**。
        static let cornerRadius: CGFloat = 8

        /// 字外面那圈内边距 —— **上下 12 · 左右 25**。
        static let contentInsets = NSDirectionalEdgeInsets(
            top: 12,
            leading: 25,
            bottom: 12,
            trailing: 25
        )

        /// 图标和字之间那条缝：**10**。
        static let iconGap: CGFloat = 10
    }

    init(title: String, systemImage: String) {
        super.init(frame: .zero)
        // 实心大按钮缩得收敛一点 —— 它比图标按钮大得多，缩同样比例边上位移太夸张。
        pressScale = 0.9

        // ⚠️ 外观走 `UIButton.Configuration`，**不用 `imageEdgeInsets` / `contentEdgeInsets`** ——
        // 那两个从 iOS 15 起废弃了，而且圆角也没地方设。
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: systemImage)
        configuration.imagePadding = Metrics.iconGap
        configuration.baseBackgroundColor = AppColor.surface
        configuration.baseForegroundColor = AppColor.accent
        // 告诉系统"圆角我说了算"：不写这行，系统会按按钮高度自己算一个（`dynamic`）。
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = Metrics.cornerRadius
        configuration.contentInsets = Metrics.contentInsets
        self.configuration = configuration

        // 按下时别叠系统那层变暗（底色 / 字色 / 图标色一起钉），按下去只靠缩放说话。
        // ⚠️ 字号传的是**取值动作**不是字体本身 —— 系统文字大小一变，它才会跟着重取。
        pinColorsAgainstHighlight(
            fill: AppColor.surface,
            text: AppColor.accent,
            font: { AppFont.playlistActionTitle }
        )
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }
}
