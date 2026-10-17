import SnapKit
import UIKit

/// 歌单封面流子页 —— 只画 3D 流和播放键，动作全回调给宿主。
///
/// 不 present 播放页、不碰播放器、不查库。
///
/// 🔴 **关闭键不在这儿**：它在宿主（`PlaylistDetailCoverFlowController`）—— 那是主 VC
/// **自己的** lazy view，菜单点下去**当场**就能露；子页 view 那会儿还没装
/// （要等转屏 prepare 才 `addChild`），键放这儿就露不出来。
///
/// 🔴 **中央只认 `centeredIndex` 一份**。
/// 摆位由宿主**按值传目标**（`recenter(to:)`）：先 `layoutIfNeeded` → 算 attrs →
/// `setContentOffset`，最后**以目标为准写回**。
final class PlaylistCoverFlowViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {

    var onTogglePlay: (() -> Void)?
    var onSelectCentered: ((Track.ID) -> Void)?
    var onOpenNowPlaying: (() -> Void)?

    private let flowLayout = PlaylistCoverFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
    private let playButton = UIButton(type: .system)
    private let feedback = UIImpactFeedbackGenerator(style: .light)
    private let symbolConfig = UIImage.SymbolConfiguration(
        pointSize: AppMetrics.coverFlowChromeIconSize,
        weight: .regular
    )

    private var items: [CoverFlowItem] = []
    private var artworkProvider: ArtworkProvider?

    /// 中央那张 —— **唯一**真相。装数据、点选、拖停、程序摆位都写它。
    private(set) var centeredIndex = 0

    var centeredItemID: Track.ID? {
        items.indices.contains(centeredIndex) ? items[centeredIndex].id : nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppColor.nowPlayingBackground
        setupCollection()
        setupChrome()
        feedback.prepare()
    }

    /// 装数据并钉行号。摆位由随后的 `recenter(to:)` 做（目标由宿主按值传来）。
    ///
    /// `reloadData` 会触发布局回调、可能把 `centeredIndex` 吸到别处 —— 摆位读的是**传进来的目标**，
    /// 不受它影响；摆完再以目标为准写回。
    func show(items: [CoverFlowItem], centeredIndex: Int, artworkProvider: ArtworkProvider?) {
        self.items = items
        self.artworkProvider = artworkProvider
        self.centeredIndex = CoverFlowGeometry.clampedIndex(centeredIndex, count: items.count)
        collectionView.reloadData()
        updateAccessibilityValue()
    }

    /// 布局标脏 —— alongside 拍的**第一件事**：`invalidateLayout()`，在切 chrome **之前**。
    ///
    /// 🔴 顺序：**标脏 → 切 chrome（揭罩）→ `layoutIfNeeded` → 摆位**。
    /// 子页自己不在揭罩前标脏，所以这一步由宿主在 `paintSurface` 里、切 chrome 之前调。
    func invalidateFlowLayout() {
        flowLayout.invalidateLayout()
    }

    /// 按**传入的**目标下标摆正（目标、动画、触觉三样都由调用方按值给）。
    ///
    /// 🔴 目标按值传入，**不读** `centeredIndex` —— 那份可能在 `reloadData` / 布局回调里被吸到别处；
    /// 摆完再以目标为准写回。入口算号、alongside 拍传进来。
    func recenter(to index: Int) {
        scrollToCenteredIndex(index, animated: false, haptic: false)
    }

    func setPlaying(_ playing: Bool) {
        let name = playing ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: name, withConfiguration: symbolConfig), for: .normal)
    }

    // MARK: - 装配

    private func setupCollection() {
        collectionView.backgroundColor = AppColor.nowPlayingBackground
        collectionView.clipsToBounds = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.decelerationRate = .fast
        // 摆位全靠自己算的 offset ⇒ 不跟系统安全区联动。
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            PlaylistCoverFlowCell.self,
            forCellWithReuseIdentifier: PlaylistCoverFlowCell.reuseIdentifier
        )
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { $0.edges.equalToSuperview() }
    }

    private func setupChrome() {
        playButton.tintColor = AppColor.overlayTextStrong
        setPlaying(false)
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        playButton.addGestureRecognizer(
            UILongPressGestureRecognizer(target: self, action: #selector(playLongPressed(_:)))
        )
        view.addSubview(playButton)
        playButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(AppMetrics.coverFlowChromeInset)
            make.bottom.equalToSuperview().offset(-AppMetrics.coverFlowChromeInset)
            make.width.height.equalTo(AppMetrics.coverFlowChromeButtonSide)
        }
    }

    // MARK: - 动作

    @objc private func playTapped() {
        onTogglePlay?()
    }

    @objc private func playLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onOpenNowPlaying?()
    }

    /// 按目标下标摆正（三步）：`layoutIfNeeded` → 算 attrs 得 x → `setContentOffset`，
    /// 最后**以目标为准写回** `centeredIndex`。
    ///
    /// - Parameter haptic: 触觉位 —— **当拍**生效（「号变了」才写 + 震），**不等**动画结束。
    private func scrollToCenteredIndex(_ index: Int, animated: Bool, haptic: Bool) {
        let clamped = CoverFlowGeometry.clampedIndex(index, count: items.count)
        flowLayout.invalidateLayout()
        collectionView.layoutIfNeeded()

        if collectionView.bounds.width > 0,
           let attrs = flowLayout.layoutAttributesForItem(at: IndexPath(item: clamped, section: 0)) {
            let viewportWidth = collectionView.bounds.width
            let inset = collectionView.adjustedContentInset
            let x = CoverFlowGeometry.clampedOffsetX(
                centeringItemCenterX: attrs.center.x,
                viewportWidth: viewportWidth,
                contentWidth: collectionView.contentSize.width,
                insetLeft: inset.left,
                insetRight: inset.right
            )
            collectionView.setContentOffset(CGPoint(x: x, y: 0), animated: animated)
        }

        // 摆完**以目标为准写回**，只在「号变了」时写 + 震。
        let changed = clamped != centeredIndex
        guard changed else { return }
        centeredIndex = clamped
        updateAccessibilityValue()
        guard haptic else { return }
        feedback.impactOccurred()
        feedback.prepare()
    }

    /// 可见格子里 `|progress|` 最小的那张就是中央。
    private func adoptNearestCenteredItem(haptic: Bool) {
        let bounds = collectionView.bounds
        guard bounds.width > 0 else { return }
        let query = CGRect(
            x: collectionView.contentOffset.x,
            y: 0,
            width: bounds.width,
            height: bounds.height
        )
        guard let attrs = flowLayout.layoutAttributesForElements(in: query)?
            .compactMap({ $0 as? PlaylistCoverFlowLayoutAttributes }),
              let nearest = attrs.min(by: { abs($0.progress) < abs($1.progress) })
        else { return }
        let item = nearest.indexPath.item
        guard item != centeredIndex else { return }
        centeredIndex = item
        updateAccessibilityValue()
        guard haptic else { return }
        feedback.impactOccurred()
        feedback.prepare()
    }

    /// 把中央那张的标题报给无障碍（VoiceOver 读出来）。
    private func updateAccessibilityValue() {
        guard items.indices.contains(centeredIndex) else {
            collectionView.accessibilityValue = nil
            return
        }
        collectionView.accessibilityValue = items[centeredIndex].title
    }

    // MARK: - UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let dequeued = collectionView.dequeueReusableCell(
            withReuseIdentifier: PlaylistCoverFlowCell.reuseIdentifier,
            for: indexPath
        )
        guard let cell = dequeued as? PlaylistCoverFlowCell,
              items.indices.contains(indexPath.item)
        else {
            assertionFailure("封面流格子必须是注册过的 PlaylistCoverFlowCell")
            return dequeued
        }
        cell.show(items[indexPath.item], artworkProvider: artworkProvider)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        adoptNearestCenteredItem(haptic: false)
        if indexPath.item == centeredIndex {
            guard items.indices.contains(centeredIndex) else { return }
            onSelectCentered?(items[centeredIndex].id)
            return
        }
        // 旁张：写唯一下标 + 动画滚 + 当拍震
        scrollToCenteredIndex(indexPath.item, animated: true, haptic: true)
    }

    /// 触觉位：`didScroll` / 减速停稳 / 动画结束走**同一条**（震）；
    /// `didEndDragging`（不减速）是唯一**显式关掉**的那条 ⇒ 不震。
    ///
    /// 🔴 震只可能落在「号变了」的那一帧 —— 也就是**拖动过程中**：拖停那拍号早被
    /// `didScroll` 认掉了，在那里传 1 也是空转（「滑了没震」的病根就在这）。
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        adoptNearestCenteredItem(haptic: true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { adoptNearestCenteredItem(haptic: false) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        adoptNearestCenteredItem(haptic: true)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        adoptNearestCenteredItem(haptic: true)
    }
}
