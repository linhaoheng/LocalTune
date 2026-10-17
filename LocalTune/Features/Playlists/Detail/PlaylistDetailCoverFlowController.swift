import SnapKit
import UIKit

/// 歌单详情**封面流协作者** —— 门控、嵌子页、chrome、强制锁、转屏。
///
/// 3D 和格子在 `Features/Playlists/CoverFlow/`。
///
/// 🔴 **该不该盖流 = 纯状态**（`CoverFlowGeometry.surface`）。
/// 转屏：入口 `prepare`（装数据，不揭罩）；alongside `paint`（chrome + 摆位 / 出流滚表）；completion 空。
/// `appliedCoverFlowSurface` 只在 **paint 末尾**写入，避免入口就标成已盖、画面还没跟上。
@MainActor
final class PlaylistDetailCoverFlowController {

    // MARK: - 依赖

    private let viewModel: PlaylistDetailViewModel
    private let router: AppRouter
    private let artworkProvider: ArtworkProvider
    private unowned let page: PlaylistDetailViewController
    private weak var listController: PlaylistDetailListController?
    private weak var locatorController: PlaylistDetailPlayingLocatorController?

    // MARK: - 状态

    /// 手机菜单「封面流」强制横屏。三处：菜单进、退出键出、真离开本页。
    private var coverFlowForceLock = false
    private var coverFlowController: PlaylistCoverFlowViewController?
    /// 现在盖到哪一步 —— **只在 paint 写**（与画面同步）。
    private var appliedCoverFlowSurface: CoverFlowSurface = .list

    /// 关闭键 —— **住在宿主**，不进子页。
    ///
    /// 它是主 VC **自己的** lazy view，所以菜单点下去**当场**就能 `setHidden(false)`。
    /// 子页那个 view 那会儿还没装（要等转屏 prepare 才 `addChild`），键放子页里就露不出来。
    private lazy var exitButton: UIButton = {
        let button = UIButton(type: .system)
        button.tintColor = AppColor.overlayTextStrong
        button.setImage(
            UIImage(
                systemName: "iphone",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: AppMetrics.coverFlowChromeIconSize,
                    weight: .regular
                )
            ),
            for: .normal
        )
        button.addAction(
            UIAction { [weak self] _ in self?.endCoverFlowForceLock(requestPortrait: true) },
            for: .touchUpInside
        )
        button.isHidden = true
        return button
    }()

    /// 露 / 藏关闭键。**第一次调用时才挂进页面**（懒加载）。
    private func setExitButtonHidden(_ hidden: Bool) {
        if exitButton.superview == nil {
            page.view.addSubview(exitButton)
            exitButton.snp.makeConstraints { make in
                make.trailing.equalToSuperview().offset(-AppMetrics.coverFlowChromeInset)
                make.bottom.equalToSuperview().offset(-AppMetrics.coverFlowChromeInset)
                make.width.height.equalTo(AppMetrics.coverFlowChromeButtonSide)
            }
        }
        exitButton.isHidden = hidden
        if !hidden { page.view.bringSubviewToFront(exitButton) }
    }

    /// 入口算好、alongside 用的一拍载荷（不长期挂出流 id）。
    private struct PreparedSurface {
        let next: CoverFlowSurface
        let wasOverlay: Bool
        /// 出流时记下的中央曲 id（出流滚表要对着它）。
        let exitSongID: Track.ID?
        /// 进 overlay 时 alongside 拍要摆到第几张。
        let centerIndex: Int?
    }

    init(
        viewModel: PlaylistDetailViewModel,
        router: AppRouter,
        artworkProvider: @escaping ArtworkProvider,
        page: PlaylistDetailViewController
    ) {
        self.viewModel = viewModel
        self.router = router
        self.artworkProvider = artworkProvider
        self.page = page
    }

    func wire(
        listController: PlaylistDetailListController,
        locatorController: PlaylistDetailPlayingLocatorController
    ) {
        self.listController = listController
        self.locatorController = locatorController
    }

    // MARK: - 生命周期

    var coverFlowInterfaceOrientations: UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        // 强制时 supported = 左右横；请求几何只说「要横的」（哪边系统按设备挑）。
        return coverFlowForceLock ? .landscape : .allButUpsideDown
    }

    func handleCoverFlowWillAppear() {
        applySurface(for: page.view.bounds.size)
    }

    func handleCoverFlowDidAppear() {
        publishOrientationNeedsUpdate()
    }

    func handleCoverFlowWillDisappear() {
        guard page.isMovingFromParent || page.isBeingDismissed else { return }
        clearForceLockAfterLeavingPage()
    }

    /// 转屏：入口 prepare；alongside paint；completion 空。
    func handleCoverFlowTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        guard !isPresentingNowPlaying else { return }
        let prepared = prepareSurface(for: size)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.paintSurface(prepared, animatedChrome: true)
        }, completion: nil)
    }

    func setPlaying(_ isPlaying: Bool) {
        coverFlowController?.setPlaying(isPlaying)
    }

    func refreshCoverFlowAfterSnapshotChange() {
        applySurface(for: page.view.bounds.size, itemsChanged: true)
    }

    // MARK: - 菜单

    func presentCoverFlowFromMenu() {
        guard let listController, !listController.songs.isEmpty, !coverFlowForceLock else { return }
        coverFlowForceLock = true
        // 置锁 → **当场露关闭键** → setNeedsUpdate → 请求转屏。
        // 🔴 **不**就地 `applySurface`：关闭键在宿主手里，这里能直接露；「已经横着、不发转屏」
        // 那种情况也就不需要靠它补画了。
        setExitButtonHidden(false)
        publishOrientationNeedsUpdate()
        // 进强制：只说「要横的」—— 哪边由系统按设备当前朝向挑。
        requestCoverFlowGeometry(.landscape)
    }

    func toggleIPadAutoCoverFlow() {
        viewModel.iPadAutoCoverFlow.toggle()
        applySurface(for: page.view.bounds.size)
    }

    // MARK: - 私有

    private var isPhoneForCoverFlow: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private var isPresentingNowPlaying: Bool {
        page.presentedViewController is NowPlayingViewController
            || page.navigationController?.presentedViewController is NowPlayingViewController
    }

    /// 清锁、藏关闭键、请求竖屏。
    /// **不**就地 `applySurface`（仍横时再算一遍是多余结构；显隐交给随后转屏 paint）。
    private func endCoverFlowForceLock(requestPortrait: Bool) {
        guard coverFlowForceLock else { return }
        coverFlowForceLock = false
        publishOrientationNeedsUpdate()
        setExitButtonHidden(true)
        if requestPortrait {
            requestCoverFlowGeometry(.portrait)
        }
    }

    private func clearForceLockAfterLeavingPage() {
        let hadLock = coverFlowForceLock
        coverFlowForceLock = false
        publishOrientationNeedsUpdate()
        if hadLock {
            requestCoverFlowGeometry(.portrait)
        }
    }

    private func applySurface(for size: CGSize, itemsChanged: Bool = false) {
        let prepared = prepareSurface(for: size, itemsChanged: itemsChanged)
        paintSurface(prepared, animatedChrome: false)
    }

    /// 第一拍：算门控 / 装数据 / **算出 alongside 要摆的目标号**。**不**写 `appliedCoverFlowSurface`、不揭罩、不写 offset。
    private func prepareSurface(for size: CGSize, itemsChanged: Bool = false) -> PreparedSurface {
        let next = CoverFlowGeometry.surface(
            isPhone: isPhoneForCoverFlow,
            width: size.width,
            height: size.height,
            iPadAutoEnabled: viewModel.iPadAutoCoverFlow,
            isEmpty: listController?.songs.isEmpty ?? true,
            forceLock: coverFlowForceLock
        )
        let wasOverlay = appliedCoverFlowSurface.isOverlay
        var exitSongID: Track.ID?
        var centerIndex: Int?

        switch next {
        case .overlay:
            installCoverFlowIfNeeded()
            // 入口先把目标号算出来（按值带进 alongside 拍），alongside 不再读可能被吸脏的号。
            let index = coverFlowIndexForShowing(preserving: wasOverlay)
            if !wasOverlay || itemsChanged {
                coverFlowController?.show(
                    items: coverFlowItems(),
                    centeredIndex: index,
                    artworkProvider: artworkProvider
                )
            }
            centerIndex = index
        case .list:
            // 出流前读唯一下标 —— 出流滚表要对着它。
            exitSongID = wasOverlay ? coverFlowController?.centeredItemID : nil
        }

        return PreparedSurface(
            next: next,
            wasOverlay: wasOverlay,
            exitSongID: exitSongID,
            centerIndex: centerIndex
        )
    }

    /// 第二拍：chrome + 摆位 / 出流滚表；**末尾**才写 `appliedCoverFlowSurface`。
    private func paintSurface(_ prepared: PreparedSurface, animatedChrome: Bool) {
        // alongside 的**第一件事**：先把封面流布局标脏，**再**切 chrome。
        coverFlowController?.invalidateFlowLayout()
        switch prepared.next {
        case .overlay(let showExit):
            applyOverlayChrome(showExit: showExit, animated: animatedChrome)
            if let centerIndex = prepared.centerIndex {
                coverFlowController?.recenter(to: centerIndex)
            }
            coverFlowController?.setPlaying(viewModel.playbackChromeNow.isPlaybackActive)

        case .list:
            applyListChrome(animated: animatedChrome)
            if let id = prepared.exitSongID {
                listController?.scrollToSong(id: id, position: .middle, animated: false)
            }
        }
        appliedCoverFlowSurface = prepared.next
    }

    // MARK: - chrome

    private func applyOverlayChrome(showExit: Bool, animated: Bool) {
        locatorController?.forceHide()
        page.bottomBlockHost?.setBottomBlockHidden(true)
        coverFlowController?.view.isHidden = false
        if let coverView = coverFlowController?.view {
            page.view.bringSubviewToFront(coverView)
        }
        // 关闭键是 `page.view` 的直接子视图 ⇒ 必须**在封面流提上来之后**再提它，否则被盖住。
        setExitButtonHidden(!showExit)
        page.navigationController?.setNavigationBarHidden(true, animated: animated)
        page.navigationController?.setToolbarHidden(true, animated: animated)
    }

    private func applyListChrome(animated: Bool) {
        setExitButtonHidden(true)
        coverFlowController?.view.isHidden = true
        page.navigationController?.setNavigationBarHidden(false, animated: animated)
        if viewModel.isSelectingNow {
            page.navigationController?.setToolbarHidden(false, animated: animated)
            page.bottomBlockHost?.setBottomBlockHidden(true)
        } else {
            page.navigationController?.setToolbarHidden(true, animated: animated)
            page.bottomBlockHost?.setBottomBlockHidden(false)
        }
        locatorController?.syncPlayingLocatorAvailability()
    }

    private func installCoverFlowIfNeeded() {
        if coverFlowController != nil { return }
        let coverFlow = PlaylistCoverFlowViewController()
        coverFlow.onTogglePlay = { [weak self] in
            self?.viewModel.togglePlayPause()
        }
        coverFlow.onSelectCentered = { [weak self] id in
            self?.viewModel.handleCoverFlowCenterTap(id: id)
        }
        coverFlow.onOpenNowPlaying = { [weak self] in
            guard self?.viewModel.playbackChromeNow.currentTrackID != nil else { return }
            self?.router.presentNowPlaying()
        }
        page.addChild(coverFlow)
        page.view.addSubview(coverFlow.view)
        coverFlow.view.snp.makeConstraints { $0.edges.equalToSuperview() }
        coverFlow.view.isHidden = true
        coverFlow.didMove(toParent: page)
        coverFlowController = coverFlow
    }

    // MARK: - 下标

    private func coverFlowItems() -> [CoverFlowItem] {
        guard let listController else { return [] }
        let rows = listController.songs
        // 艺人一次建表 —— 别每首一个 `first(where:)`（那是 O(n²)）。
        let artists = viewModel.artistNames(for: rows.map(\.id))
        return rows.map { row in
            CoverFlowItem(
                id: row.id,
                title: row.title,
                artist: artists[row.id] ?? "",
                artworkPath: row.artworkPath
            )
        }
    }

    /// `preserving`：已在流里 → 保住当前 id；否则瞄正在播（不看列表视口）。
    private func coverFlowIndexForShowing(preserving: Bool) -> Int {
        guard let listController else { return 0 }
        let ids = listController.songs.map(\.id)
        if preserving {
            return CoverFlowGeometry.index(
                preserving: coverFlowController?.centeredItemID,
                in: ids,
                previousIndex: coverFlowController?.centeredIndex ?? 0
            )
        }
        return CoverFlowGeometry.index(
            preserving: viewModel.playbackChromeNow.currentTrackID,
            in: ids,
            previousIndex: 0
        )
    }

    // MARK: - 方向

    private func publishOrientationNeedsUpdate() {
        page.setNeedsUpdateOfSupportedInterfaceOrientations()
        page.tabBarController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        page.navigationController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// 发几何请求。
    ///
    /// 🔴 横屏请求**只说「要横的」**（`.landscape`，左右两边都放行），绝不点名哪一边
    /// —— 和播放页 `requestGeometry(.landscape, …)` 同一条规矩：「界面朝哪边」只能由
    /// **设备**一个来源决定。点名写死的后果听得见也看得见（曾经这里是 `.landscapeRight`）：
    /// 设备已经左横屏时，界面先被拧到右横、等请求落地系统再按设备拧回来 ⇒
    /// 用户看着「先左转再右转」。
    /// 竖屏请求（出强制回竖）是单值，没有这个歧义。
    private func requestCoverFlowGeometry(_ mask: UIInterfaceOrientationMask) {
        guard let scene = page.view.window?.windowScene else { return }
        // 转屏失败不做任何事，不补回滚（errorHandler 空块）。
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

private extension CoverFlowSurface {
    var isOverlay: Bool {
        if case .overlay = self { return true }
        return false
    }
}
