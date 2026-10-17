import ObjectiveC
import PanModal
import RxSwift
import UIKit

/// 页面的**组装处** + 跳转的**唯一出口**。
///
/// 这两件事归同一个地方，因为它们本来就是一件事的两头：
/// - **造页面** —— 目标页要什么依赖，只有这里知道（`AppServices` → `AppRouter` → 页面）；
/// - **跳转** —— 页面自己想跳，只跟它说"去哪一页"，怎么推由这里决定。
///
/// 反过来说，页面自己 `pushViewController` 的话，「这个 App 到底能跳去哪些页」就没有一处
/// 能回答 —— 想知道得把每个页面翻一遍；目标页要什么依赖，也会变成每个页面各自去凑。
///
/// ## 第三件事：**模态形态**（`presentAsSheet`）
///
/// 弹出来的那一页 / 那条栈长什么样 —— `.pageSheet` ＋ 一档 `.large()` ＋ 要不要小白条 ——
/// **只有这一处**决定（全 App 8 处入口都走它）。
/// 🔴 **它不归 `AppNavigationController`**：要收的东西里**有不是栈的**（歌词海报页弹的是一个
/// 光杆 `UIViewController`），挂在栈基类上收不全。栈基类只管「一条栈穿什么皮」。
///
/// ⚠️ 它绑的是**一条**导航栈 —— 每个 tab 各有一条栈，所以**每个 tab 一个 Router**。
///
/// ⚠️ **整个类是 `@MainActor`**：造页面、推栈、弹窗全是主线程的事，
/// 页面（及其协作者）也都是 `@MainActor` —— 同一条线程上的约定就写在明面上。
@MainActor
final class AppRouter {

    /// 服务容器 —— 造页面时从这里取依赖往下发。
    private let services: AppServices

    /// 当前所在的那条导航栈。
    ///
    /// ⚠️ **弱引用**：栈归容器（`MainTabBarController`）持有，Router 不延长它的命。
    /// 用强引用的话，页面都退完了栈还留着，Router 就成了它的坟。
    private weak var navigationController: UINavigationController?

    init(services: AppServices) {
        self.services = services
    }

    /// 绑上导航栈 —— 容器把栈造好之后调一次。
    ///
    /// 为什么分两步、不在构造时就传：栈的根页面要拿到 Router，
    /// 而栈要等根页面造好才能造 —— 互相持有就转不出来了。
    func attach(to navigationController: UINavigationController) {
        self.navigationController = navigationController
    }

    // MARK: - 造页面

    /// 曲库页 —— 底部第一个 tab 的根页面。
    ///
    /// ⚠️ 曲库页的跨页动作（多选添加到播放列表）也只通过本 Router 出去；
    /// 页面不直接创建或呈现歌单选择页。
    func makeSongsViewController() -> UIViewController {
        SongsViewController(
            library: services.library,
            importService: services.importService,
            trackRemover: services.trackRemover,
            settings: services.settings,
            playManager: services.playManager,
            router: self,
            artworkProvider: AppArtwork.image
        )
    }

    /// 歌单页 —— 底部第二个 tab 的根页面。
    ///
    /// ⚠️ **不给播放器**：这一页自己不播任何东西（原先行尾菜单里那个「全部播放」要用它，
    /// 那一项已删）。播一个歌单走「进详情页 → 播放」那条路。
    ///
    /// ⚠️ 路由要给：点一行进歌单详情页，跳转只从这儿出去。
    func makePlaylistsViewController() -> UIViewController {
        PlaylistsViewController(
            library: services.library,
            covers: services.covers,
            settings: services.settings,
            router: self,
            artworkProvider: AppArtwork.image
        )
    }

    /// 歌曲页多选后进入的歌单选择模式 —— 仍然复用歌单页，不另造挑歌单页。
    func makeAddTracksToPlaylistsViewController(trackIDs: [Track.ID]) -> UIViewController {
        PlaylistsViewController(
            library: services.library,
            covers: services.covers,
            settings: services.settings,
            router: self,
            artworkProvider: AppArtwork.image,
            addingTrackIDs: trackIDs
        )
    }

    /// 弹出复用歌单页的「添加到播放列表」模式 —— 默认从当前导航栈 present。
    ///
    /// 曲库 / 歌单行尾走这条（那时栈上通常没有盖着的播放页）。
    func presentAddTracksToPlaylists(trackIDs: [Track.ID]) {
        guard let navigationController else {
            assertionFailure("跳转之前必须先由容器把导航栈绑上")
            return
        }
        presentAddTracksToPlaylists(trackIDs: trackIDs, from: navigationController)
    }

    /// 从指定 presenter 弹出「添加到播放列表」。
    ///
    /// 🔴 **播放页必须走这条**：播放页本身已是 nav 上的 presented（PanModal），
    /// 再从 nav present 会被 `presentedViewController != nil` 挡掉（silent return）。
    /// 呈现主体改成播放页自己，sheet 盖在播放页上；关掉后仍停在播放页。
    ///
    /// ⚠️ detent / 无 grabber 与曲库入口**同一套**（禁止同一交互两套壳）。
    func presentAddTracksToPlaylists(
        trackIDs: [Track.ID],
        from presenter: UIViewController
    ) {
        presentAsSheet(from: presenter) {
            let picker = makeAddTracksToPlaylistsViewController(trackIDs: trackIDs)
            return SheetRequest(
                page: AppNavigationController(rootViewController: picker, surface: .grouped)
            )
        }
    }

    /// 歌单详情页 —— 从歌单列表点一行进去。
    func makePlaylistDetailViewController(id: Playlist.ID) -> UIViewController {
        PlaylistDetailViewController(
            playlistID: id,
            library: services.library,
            covers: services.covers,
            settings: services.settings,
            trackRemover: services.trackRemover,
            playManager: services.playManager,
            router: self,
            artworkProvider: AppArtwork.image
        )
    }

    /// 「添加歌曲到歌单」页 —— 从歌单详情页那个「加号」弹出来（见下面的目的地）。
    ///
    /// ⚠️ **不给播放器**：这一页只挑歌、不播任何东西（点一行是勾选，见它的 `+List`）。
    func makeAddSongsViewController(playlistID: Playlist.ID) -> AddSongsViewController {
        AddSongsViewController(
            playlistID: playlistID,
            library: services.library,
            settings: services.settings,
            artworkProvider: AppArtwork.image
        )
    }

    /// 歌曲信息编辑页。
    ///
    /// ⚠️ `try?` 敢吞：菜单点下到 present 之间歌可能已被删；`nil` 不抛错，
    /// 由 `presentTrackEditor` 弹「这首歌已经不在曲库里了」。
    func makeTrackEditorViewController(trackID: Track.ID) -> TrackEditorViewController? {
        guard let track = try? services.library.track(id: trackID) else { return nil }
        return TrackEditorViewController(
            viewModel: TrackEditorViewModel(track: track, library: services.library),
            artworkProvider: AppArtwork.image
        )
    }

    /// 「获取歌词」页 —— 从编辑歌词页右上那颗键**推上去**（见下面的目的地）。
    ///
    /// ⚠️ **不给播放器、不给曲库**：这一页只搜词、下词、把外部逐字档转成我们的正文 ——
    /// 转好之后交给 `onFetched` 就完事，灌工作层和落库都是编辑页的事。
    /// 它唯一的外部依赖就是那个取词客户端。
    func makeLyricsFetchViewController(
        track: Track,
        onFetched: @escaping (String) -> Void
    ) -> LyricsFetchViewController {
        LyricsFetchViewController(
            viewModel: LyricsFetchViewModel(
                track: track,
                client: services.lyricsClient,
                onFetched: onFetched
            )
        )
    }

    // MARK: - 目的地

    /// 弹出歌曲信息编辑页 —— 从曲库行尾「更多 → 编辑歌曲信息」进。
    ///
    /// `pageSheet` + 只留 `.large()`；右上关闭。跳转只从这儿出去。
    func presentTrackEditor(trackID: Track.ID) {
        guard let navigationController else {
            assertionFailure("跳转之前必须先由容器把导航栈绑上")
            return
        }
        presentAsSheet(from: navigationController) {
            guard let editor = makeTrackEditorViewController(trackID: trackID) else {
                HUD.showMessage("这首歌已经不在曲库里了")
                return nil
            }
            // 下拉关闭的决策者**在创建现场显式给** —— 这一刻类型是具体的，
            // 不靠「栈顶长得像不像」去 `as?` 猜（那是在拿运行时行为赌）。
            return SheetRequest(
                page: AppNavigationController(rootViewController: editor, surface: .secondary),
                dismissalDecider: editor.presentationDelegate
            )
        }
    }
    /// 推进某个歌单的详情页。
    func pushPlaylistDetail(id: Playlist.ID) {
        push(makePlaylistDetailViewController(id: id))
    }

    /// 弹出「添加歌曲到歌单」页 —— 从歌单详情页右上那个「加号」进。
    ///
    /// ⚠️ **它是弹出来的（模态）、不是推进栈里的**：这一页干完活就关（取消 / 完成），
    /// 关掉之后回到的还是同一个歌单详情页 —— 压进栈里反而多出一层"返回"，
    /// 而且那一层的"返回"到底是加还是不加，语义上说不清。
    ///
    /// 🔴 **呈现参数在这儿给**（这一页只有这一处入口）：
    /// `pageSheet` + 只留 `.large()` 一档。
    /// `.large()` 这一档是**能往下拖走的**，拖走就等于取消。
    ///
    /// ⚠️ **别加 `isModalInPresentation`**：一加就拖不动了。**能拖**（拖走 = 取消）。
    /// ⚠️ 也不要那把小白条（grabber）："能拖"靠 sheet 自己的手势就成立。
    ///
    /// ⚠️ **这一页要包一层导航栏**：它左右两颗键（取消 / 完成）和大标题都挂在导航栏上。
    /// 那层 `UINavigationController` 是**另起的一条**（不是容器那条 `MiniBarNavController`）——
    /// 模态页有自己的栏，也不用迷你播放条让位（它盖在上面）。
    func presentAddSongs(to playlistID: Playlist.ID) {
        guard let navigationController else {
            assertionFailure("跳转之前必须先由容器把导航栈绑上")
            return
        }
        presentAsSheet(from: navigationController) {
            let page = makeAddSongsViewController(playlistID: playlistID)
            // 下拉关闭的决策者**在创建现场显式给** —— 同 `presentTrackEditor`，不靠 `as?` 猜。
            return SheetRequest(
                page: AppNavigationController(rootViewController: page, surface: .grouped),
                dismissalDecider: page.presentationDelegate
            )
        }
    }

    /// 退回去 —— 页面发现「我这一页不该继续存在了」（比如它显示的那个歌单被删了）时请它退。
    ///
    /// ⚠️ 只退**栈顶那一页**：传进来的不是栈顶就什么都不做 —— 那说明用户已经走得更深、
    /// 或者这一页上面盖着别的东西，这时候退会把**别人**弹掉。
    func pop(from page: UIViewController) {
        guard let navigationController, navigationController.topViewController === page else { return }
        navigationController.popViewController(animated: true)
    }

    /// 从底部升起「正在播放」页。
    ///
    /// ⚠️ **它不是 push** —— 播放页是**模态**：从底部升起、能往下拖走。
    /// 所以它不走上面那个私有 `push`，但**仍然只从这儿出去**，"跳转的唯一出口"这条规矩不变。
    ///
    /// 🔴 **无当前曲不打开** —— 迷你条「未在播放」可点，这里静默 return。
    /// 所有入口（点子条 / 点正在播的行）都走这儿，门只留这一道。
    ///
    /// 呈现走 `PanModal`（`Libraries/PanModal`）。
    ///
    /// ⚠️ **为什么不用系统自带的**：系统那两档都做不出「盖满 + 能拖」——
    /// `.fullScreen` 盖满但拖不动，`.pageSheet` 能拖但盖不满（要 iOS 18 才补上）。
    /// 它盖多满、要不要圆角、能不能拖走，全在 `NowPlayingViewController` 那段
    /// `PanModalPresentable` 里 —— **呈现参数跟着页面走**，只有那一页知道它该长什么样。
    ///
    /// 🔴 **它要的两样依赖也在这儿给**：
    /// - 页面状态的那个 VM —— 页面自己**不认识播放器**，只认 VM；
    /// - 取封面的**动作** —— `AppArtwork.image`，跟迷你条用的是同一个（两处共用一处实现）。
    ///   ⚠️ 给的是动作不是一张图：封面要多大由版式定、屏幕倍数会变，那两件事只有视图自己知道。
    func presentNowPlaying() {
        guard let navigationController else {
            assertionFailure("跳转之前必须先由容器把导航栈绑上")
            return
        }
        presentPanModal(from: navigationController) {
            // 🔴 无当前曲不许打开 —— 跟 showPlayView 那条门闩同一个效果。
            // 迷你条「未在播放」仍可点，这里静默 return（不弹空壳页）。
            guard services.playManager.hasCurrentTrack else { return nil }

            let viewModel = NowPlayingViewModel(
                playManager: services.playManager,
                library: services.library,
                settings: services.settings,
                trackRemover: services.trackRemover,
                lyricsManager: services.lyricsManager,
                artworkPalette: AppArtwork.palette,
                paletteScheduler: ConcurrentDispatchQueueScheduler(qos: .userInitiated)
            )
            return NowPlayingViewController(
                viewModel: viewModel,
                artworkProvider: AppArtwork.image,
                router: self
            )
        }
    }

    /// 从播放页弹出均衡器（强制黑皮，无 grabber）。
    func presentEqualizer(from presenter: UIViewController) {
        presentAsSheet(from: presenter) {
            let page = EqualizerViewController(
                viewModel: EqualizerViewModel(session: services.effects)
            )
            return SheetRequest(
                page: AppNavigationController(rootViewController: page, surface: .nowPlaying)
            )
        }
    }

    /// 从播放页弹出速度页（分组列表，不大涂黑）。
    func presentPlaybackSpeed(from presenter: UIViewController) {
        presentAsSheet(from: presenter, grabber: true) {
            let page = PlaybackSpeedViewController(session: services.effects)
            return SheetRequest(
                page: AppNavigationController(rootViewController: page, surface: .secondary)
            )
        }
    }

    /// 从播放页弹出定时关闭（分组列表，跟速度页同一套皮）。
    func presentSleepTimer(from presenter: UIViewController) {
        presentAsSheet(from: presenter, grabber: true) {
            let page = SleepTimerViewController(session: services.sleep)
            return SheetRequest(
                page: AppNavigationController(rootViewController: page, surface: .secondary)
            )
        }
    }

    /// 从播放页弹出队列页（半屏）。
    ///
    /// 🔴 **呈现主体是播放页自己**（同 `presentAddTracksToPlaylists(trackIDs:from:)`）：
    /// 播放页已经是导航栈上那个被弹出来的页面，从栈上再弹会被挡掉。
    /// 弹成什么样（多高、能不能拖走）写在 `QueueViewController` 的 `PanModalPresentable` 里。
    func presentQueue(from presenter: UIViewController) {
        presentPanModal(from: presenter) {
            QueueViewController(viewModel: QueueViewModel(playManager: services.playManager))
        }
    }

    /// 从播放页弹出**歌词显示设置**（小弹层、按内容高）。
    ///
    /// 🔴 **呈现主体是播放页自己**（同 `presentQueue`）：播放页已经是导航栈上那个被弹出来的页面，
    /// 从栈上再弹会被挡掉。弹成什么样（多高、能不能拖走、点外面关不关）写在
    /// `LyricsSettingsViewController` 的 `PanModalPresentable` 里。
    ///
    /// ⚠️ 面板只**收一份外观、报出新的那一份**（`onChange` 那条口子）—— 写 `AppSettings`
    /// 和把新值摆到歌词列表上都是**播放页**的事，面板不认识设置、也不认识播放器。
    func presentLyricsSettings(
        from presenter: UIViewController,
        appearance: LyricsAppearance,
        onChange: @escaping (LyricsAppearance) -> Void
    ) {
        presentPanModal(from: presenter) {
            LyricsSettingsViewController(appearance: appearance, onAppearanceChange: onChange)
        }
    }

    /// 从播放页弹出「编辑歌词」—— **模态整页**（左关闭 / 右保存）。
    ///
    /// ## 🔴 形态
    ///
    /// - **模态整页，不是 PanModal 底弹层** —— 底弹层是播放页自己的形态（`presentQueue` 那几个），
    ///   这一页是"进去改一首歌的词、改完走人"，整页才放得下三个模式 ＋ 逐行表格。
    /// - `pageSheet` + 只留 `.large()` 一档，**不要 grabber**。
    /// - ⚠️ **不加 `isModalInPresentation` 的那句在 Router**：`LyricsEditorViewController` 自己设了
    ///   `isModalInPresentation = true`（这一页有未存草稿，拖走等于无声丢掉）。
    ///
    /// ## 呈现主体是播放页自己
    ///
    /// 同 `presentQueue` / `presentAddTracksToPlaylists(_:from:)`：播放页已经是导航栈上那个被弹出来的页面，
    /// 从栈上再弹会被 `presentedViewController != nil` 静默挡掉。
    ///
    /// ## 歌词从哪儿取
    ///
    /// `LyricsSourcePolicy.text(for:lyrics:)` —— **判断只有那一处**（`customLyrics` 非空优先，落回内嵌）。
    /// Router 只负责把那份原文递给 VM，**不自己判优先级**。
    func presentLyricsEditor(from presenter: UIViewController, trackID: Track.ID) {
        presentAsSheet(from: presenter) {
            // 敢吞 `try?` 这一下：点进来到 present 之间歌可能已被删；读不出来就丢给下面
            // 「不在曲库里了」那句提示 —— 不抛错、也不静默。
            guard let track = try? services.library.track(id: trackID) else {
                HUD.showMessage("这首歌已经不在曲库里了")
                return nil
            }
            // 内嵌歌词住在侧表，跟 `track` 分开取。
            let lyrics = try? services.library.lyrics(for: trackID)
            let page = LyricsEditorViewController(
                viewModel: LyricsEditorViewModel(
                    track: track,
                    // 一句都没有也给 `""`：页面永远有一行空行可编辑（`LyricsEditorPolicy.parse` 的口径），
                    // 不弹"这首歌没有歌词"的空壳页。
                    lyrics: LyricsSourcePolicy.text(for: track, lyrics: lyrics) ?? "",
                    library: services.library,
                    playManager: services.playManager
                ),
                playManager: services.playManager,
                artworkProvider: AppArtwork.image,
                router: self
            )
            return SheetRequest(
                page: AppNavigationController(rootViewController: page, surface: .page)
            )
        }
    }

    /// 把「获取歌词」页**推上编辑页那条导航栈** —— 编辑页右上那颗「获取歌词」进。
    ///
    /// ## 形态
    ///
    /// **推进去，不再弹一层**：编辑页本身就是模态整页，取材是它内部的一步，挑完就回到它；
    /// 自己再弹一层，只会多出一条"退回去算取消还是算改"的糊账。
    /// ⚠️ 所以推的那条栈**不是本 Router 绑的那条**，而是 `presenter`（编辑页）自己所在的模态栈。
    ///
    /// ## 🔴 「退回去」那一下也归这里
    ///
    /// 取到词之后是两件事：**灌工作层**（调用方给的 `onFetched`）**＋ 退回去** ——
    /// 后一件是导航，所以由路由在同一个闭包里做完（页面既不知道谁在它下面，也不做
    /// `popViewController`，见宪法 §二「页面跳转」）。
    ///
    /// ⚠️ 闭包**弱引用那条栈**：页面攥着这个闭包、闭包又攥着栈，不弱引用就是个环。
    func pushLyricsFetch(
        from presenter: UIViewController,
        track: Track,
        onFetched: @escaping (String) -> Void
    ) {
        guard let navigation = presenter.navigationController else {
            assertionFailure("取材页要推在编辑页那条栈上 —— 编辑页不该是光杆一个")
            return
        }
        let page = makeLyricsFetchViewController(track: track) { [weak navigation] text in
            onFetched(text)
            navigation?.popViewController(animated: true)
        }
        navigation.pushViewController(page, animated: true)
    }

    /// 弹出歌词海报页 —— 播放页「更多 → 分享歌词」进。
    ///
    /// ## 呈现主体是播放页自己
    ///
    /// 同 `presentLyricsEditor`：播放页已经是导航栈上那个被弹出来的页面，
    /// 从栈上再弹会被 `presentedViewController != nil` 静默挡掉。
    ///
    /// ## 歌词从哪儿取
    ///
    /// `LyricsSourcePolicy.text(for:lyrics:)` —— **判断只有那一处**（`customLyrics` 非空优先，落回内嵌），
    /// 与本页显示的歌词是同一份。拿到原文再交给 `LyricsParser` 解析成行。
    ///
    /// ## 面板是 SwiftUI 写的
    ///
    /// 这是全项目第一处 SwiftUI 界面，所以由 `LyricsPosterHostingController` 包一层壳递出去
    /// —— 页面世界这边看到的仍然是一个普通的 `UIViewController`（同 `presentQueue` 那种口径）。
    ///
    /// ⚠️ 面板拿到的**是一份快照**：开着它的时候用户继续听歌、切歌，海报上的词不跟着变
    /// —— 用户挑的是刚才那几句。
    func presentLyricPoster(
        from presenter: UIViewController,
        trackID: Track.ID,
        playbackPosition: TimeInterval
    ) {
        presentAsSheet(from: presenter) {
            // 敢吞 `try?` 这一下：点进来到 present 之间歌可能已被删；读不出来就丢给下面
            // 「不在曲库里了」那句提示 —— 不抛错、也不静默。
            guard let track = try? services.library.track(id: trackID) else {
                HUD.showMessage("这首歌已经不在曲库里了")
                return nil
            }
            // 菜单是展开那一刻算的，这中间歌可能刚被清掉歌词 —— 一句都没有就没什么可分享的。
            // 内嵌歌词住在侧表，跟 `track` 分开取。
            let lyrics = try? services.library.lyrics(for: trackID)
            guard let text = LyricsSourcePolicy.text(for: track, lyrics: lyrics) else {
                HUD.showMessage("这首歌还没有歌词")
                return nil
            }

            let composer = LyricsPosterComposer.make(
                track: track,
                lyrics: LyricsParser.parse(text),
                playbackPosition: playbackPosition,
                artworkProvider: AppArtwork.image,
                paletteProvider: AppArtwork.palette,
                settings: services.settings
            )
            return SheetRequest(page: LyricsPosterHostingController(composer: composer))
        }
    }

    // MARK: - 私有

    /// 一次「弹出」要的东西：页面 ＋ 下拉关闭的决策者（没有就是 `nil`）。
    ///
    /// ⚠️ 为什么要一个类型、而不是让 `makePage` 直接返回 `UIViewController`：
    /// 决策者得**从建好的那一页身上取**（`editor.presentationDelegate`），
    /// 所以它只能跟页面一起、在建页那一步交出来。
    private struct SheetRequest {
        let page: UIViewController
        var dismissalDecider: UIAdaptivePresentationControllerDelegate? = nil
    }

    /// 把一页（或一条栈）按**我们的模态形态**弹出来 —— **全 App 只有这一处**决定模态形态。
    ///
    /// 覆盖 **8 处入口**：7 条模态栈 ＋ 歌词海报页（它**没有栈**）。
    /// ⚠️ 收口**前**是 9 个写者 —— 多出来那个是 `EqualizerViewController` 页面里
    /// 自己又写了一遍（重复写者，不是第 9 个入口），收口时已删。
    /// ⚠️ **形态不放在 `AppNavigationController` 上** —— 要收的东西里**有不是栈的**
    /// （海报页弹的是一个光杆 `UIViewController`），挂在栈上收不全。详见
    /// `docs/计划/导航栈收口落地方案.md` §〇之二 **S2**。
    ///
    /// 🔴 **门闩也在这儿**：`presenter` 上面已经盖着东西 ⇒ **什么都不做，连页面都不造**。
    /// 这条原来在 8 个调用点各写一遍，漏一处就变成「点了没反应」。
    /// 之所以让页面**晚一步**造（`make` 而不是直接传页面）：造页面那一步会带副作用 ——
    /// 读库、弹「不在曲库里了」的提示，那些都必须发生在门闩**之后**。
    ///
    /// - `.pageSheet` / `.large()` 都是 `modalPresentationStyle` / `detents` 的**默认值**，
    ///   写出来是为了**读起来清楚**：「这一页是弹的、只有一档、能往下拖走」是它的性质，
    ///   不该靠「默认值恰好是它」去猜。
    /// - `grabber`：要不要那把小白条。速度页 / 定时页要，其余不要。
    /// - `make`：**建页面那一步**，返回 `nil` ＝ 这次不弹（提示已经在里面给过了）。
    ///   里面的 `dismissalDecider` 是**下拉关闭的决策者** —— 只有页面自己知道有没有没存的东西
    ///   （编辑页的草稿、挑歌页的勾选）。⚠️ **在创建现场显式给**：这一刻类型是具体的，
    ///   不靠「栈顶长得像不像」去 `as?` 猜（那是在拿运行时行为赌）。
    ///   🔴 **交出来之后由这一处替它保命**（`retainDismissalDecider`）—— 调用方不必操心谁持有它。
    ///
    /// ⚠️ **不碰 `isModalInPresentation`** —— 那是页面自己的事：有未存草稿的页面自己设 `true`
    /// （拖走等于无声丢掉），其余页面留系统默认（拖走 = 取消）。
    private func presentAsSheet(
        from presenter: UIViewController,
        grabber: Bool = false,
        make: () -> SheetRequest?
    ) {
        guard presenter.canPresentOverlay, let request = make() else { return }
        let page = request.page
        page.modalPresentationStyle = .pageSheet
        if let sheet = page.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = grabber
        }
        if let decider = request.dismissalDecider {
            retainDismissalDecider(decider, for: page)
            page.presentationController?.delegate = decider
        }
        presenter.present(page, animated: true)
    }

    /// 弹一个 `PanModal` 页 —— **门闩在这儿**，判据与 `presentAsSheet` 同一条。
    ///
    /// ⚠️ **为什么不并进 `presentAsSheet`**：`PanModal` 有它自己的呈现通道
    /// （`presentPanModal`，换 `transitioningDelegate`），不是 `present` 一句能替代的；
    /// 能合的是**判据**，不是通道 —— 所以两条路各有一个出口，出口里都问 `canPresentOverlay`。
    ///
    /// 🔴 **返回类型必须是 `UIViewController & PanModalPresentable`，不是裸 `UIViewController`**：
    /// `presentPanModal` 要的是 `PanModalPresentable.LayoutType`，也就是这两者的组合。
    /// 照 `presentAsSheet` 的形状写成裸 `UIViewController` 会把「它遵循 PanModalPresentable」
    /// 这半边信息**在参数上就擦掉** —— 于是三个调用点明明交的是具体类型，到这一行照样编不过。
    /// 两个出口的**约束本来就不同**（`present` 收任意页面，`presentPanModal` 只收能当底弹层的），
    /// 签名得各按各的要什么写，不能照着对齐。
    ///
    /// - Parameter make: 建页面那一步，返回 `nil` ＝ 这次不弹（比如没有当前曲）。
    private func presentPanModal(
        from presenter: UIViewController,
        make: () -> (UIViewController & PanModalPresentable)?
    ) {
        guard presenter.canPresentOverlay, let page = make() else { return }
        presenter.presentPanModal(page)
    }

    /// 替下拉关闭的决策者**保命** —— UIKit 那个 `delegate` 是 `weak` 的。
    ///
    /// 🔴 **为什么必须有这一步**：`UIAdaptivePresentationControllerDelegate` 是个 `weak` 属性。
    /// 传进来的是「页面身上那个协作者」（`TrackEditorViewController.presentationDelegate` /
    /// `AddSongsViewController.presentationDelegate`，都是 `actionsController`）——
    /// **原来只有页面持有它**，靠一句注释写着"页面会强持有"来维持。页面哪天换个写法、
    /// 或者把那个协作者改成临时对象，弱引用就当场变 `nil`，
    /// 于是「拖走之前先问一句有没有没存的草稿」**静默消失** —— 用户以「我的草稿没了」的方式遇到。
    /// 一句断言拦不住这件事（赋值那一刻对象当然还活着），能拦住的是**把持有权收进来**。
    ///
    /// 🔴 **为什么挂在「被弹出来的那一页」身上**：它就是这张 sheet（栈弹的是栈、光杆页弹的是页），
    /// **它的寿命 ＝ 这张 sheet 的寿命**。页面走了，这个强引用跟着走 ——
    /// 不用登记表、不用清理回调，也就没有"忘了清"这条路（登记表那种做法要回答"什么时候清"，
    /// 那又是一个新的判据、新的漏点）。
    private func retainDismissalDecider(
        _ decider: UIAdaptivePresentationControllerDelegate,
        for page: UIViewController
    ) {
        objc_setAssociatedObject(
            page,
            &Self.dismissalDeciderKey,
            decider,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// 关联对象的键 —— 只要地址唯一，值是什么不重要。
    private static var dismissalDeciderKey: UInt8 = 0

    /// 往当前这条栈上推一页。
    ///
    /// 没绑栈就跳 = 有人把页面拿去单独用了（那种用法根本不该存在）——
    /// 开发期直接炸出来，别让它变成"点了没反应"这种事后查不出的问题。
    private func push(_ page: UIViewController) {
        guard let navigationController else {
            assertionFailure("跳转之前必须先由容器把导航栈绑上")
            return
        }
        // ⚠️ **「藏标签栏」不在这儿设了**（搬走）——
        // 它连同"给新页让位"一起搬进了 `MiniBarNavController.pushViewController`。
        // 理由：那两件事都是**导航容器自己的事**（条子就住在它里面），
        // 而且那个开关必须在转场开始**之前**设，放在导航容器里离 `super.push` 最近、最不容易漏。
        // ⚠️ 根页面不受影响：它们不是从这儿推的（是容器的 `rootViewController`），标签栏照常显示。
        navigationController.pushViewController(page, animated: true)
    }
}
