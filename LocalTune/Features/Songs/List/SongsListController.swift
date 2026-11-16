import UIKit

/// 曲库页**列表协作者** —— 怎么分段、行怎么消失、差量怎么落表，都在这儿；
/// 段头的字母和索引条那三个问题由 `SongListDataSource` 回答（它归这里建、归这里持有）。
///
/// 页面私有协作者：`rowsByID`（行内容按 id 索引）跟行走在这儿。
/// 行尾菜单的动作经 `actionsController` 出去、滚动露钮经 `locatorController` 出去，
/// 都是页面装配时接好的（见 `SongsViewController`）。
///
/// **一个 tableView 一个 delegate 对象**：`UITableViewDelegate`（点行 / 滚动）也归这里 ——
/// 点行把动作转给 VM，滚动那几个回调转给定位钮。
@MainActor
final class SongsListController: NSObject {

    // MARK: - 依赖

    private let viewModel: SongsViewModel

    /// 跳转 —— 点一行打开播放页是这一条路（只从 `AppRouter` 出去）。
    private let router: AppRouter

    /// 取图的动作 —— 装配层（`App/AppArtwork.image`）经页面递进来，配行时挂到行上。
    private let artworkProvider: ArtworkProvider

    private unowned let tableView: UITableView

    /// 索引条按下时、屏幕正中那个气泡 —— 归页面装配（压在页面正中），这里只管显示它。
    private unowned let indexBubble: IndexBubble

    /// 行尾「更多」菜单里那几个动作的归处。
    private unowned let actionsController: SongsActionsController

    /// 滚动回调的归处（定位钮本体在那边）。
    private weak var locatorController: SongsPlayingLocatorController?

    // MARK: - 状态

    /// 当前列表里的行，按 id 索引 —— 配置行时按 id 取。
    ///
    /// ⚠️ 不能让行按 `indexPath.row` 去数组里取：差量刷新做动画的那几帧，
    /// 表格里的行和数组是**对不上**的（数组已经换成新的，行还停在旧位置上）。
    private var rowsByID: [Track.ID: SongRow] = [:]

    /// 列表的数据源 —— 差量刷新：只动变了的行，不整表重刷。
    ///
    /// ⚠️ 建好的那一下就**显式接给表格**（原来页面 `layoutTableView` 里那一句，
    /// 搬到这里跟数据源建的地方放一起）。
    private lazy var dataSource: SongListDataSource = {
        let source = makeDataSource()
        tableView.dataSource = source
        return source
    }()

    init(
        viewModel: SongsViewModel,
        tableView: UITableView,
        router: AppRouter,
        artworkProvider: @escaping ArtworkProvider,
        indexBubble: IndexBubble,
        actionsController: SongsActionsController,
        locatorController: SongsPlayingLocatorController
    ) {
        self.viewModel = viewModel
        self.tableView = tableView
        self.router = router
        self.artworkProvider = artworkProvider
        self.indexBubble = indexBubble
        self.actionsController = actionsController
        self.locatorController = locatorController
        super.init()
        // delegate 在构造时认领 —— 挂接和"这个对象存在"是同一件事，
        // 装配方没有"建了它、忘了挂"的机会。数据源是差量源，建好的那一下就
        // 接给表格（建与挂是同一个表达式，见 `dataSource`），两头都拆不散。
        tableView.delegate = self
    }

    // MARK: - 快照落表

    /// 列表内容换了 —— 先分段，再让数据源算出差异，只有变了的行会动。
    ///
    /// - Returns: 这一份列表里全部行的 id（按画面顺序）—— 调用方拿它收拾选中集合。
    @discardableResult
    func apply(_ snapshot: SongsViewModel.Snapshot) -> [Track.ID] {
        // 「升还是降」在这里读**一次**，分段和索引条都用它 ——
        // 两处各读一遍状态，迟早会出现"段反了、条没反"这种对不上的组合。
        let descending = viewModel.sortDirection == .descending
        let sections = makeSections(from: snapshot, descending: descending)
        let rows = sections.flatMap(\.rows)
        // 分段用了系统 collation，顺序可能和 `SongSort` 不一致 —— 播放队列跟画面走。
        viewModel.syncPlayOrder(toVisibleIDs: rows.map(\.id))

        // 上一屏画过、**内容却变了**的那几行（换了封面、改了标签）。
        //
        // 🔴 差量刷新只认「行有没有增减」：`SongRow.id` 没变就算"同一行"，
        // 内容变了它也**不会重画** —— 表现就是"数据已经变了，界面上还是旧的"，
        // 得等那一行被滚出屏幕、cell 被复用才更新。列出来请表格原地重画一次。
        //
        // ⚠️ 新来的行不算（`rowsByID` 里没有）：它们由插入动画负责，不该走这条路。
        let changedRows = Set(
            rows.filter { row in
                guard let drawn = rowsByID[row.id] else { return false }
                return drawn != row
            }
            .map(\.id)
        )

        rowsByID = Dictionary(
            rows.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        applySections(sections, descending: descending, reconfiguring: changedRows)

        return rows.map(\.id)
    }

    /// 播放态变了 / 进出多选 —— 只重配**屏幕上看得见的行**的蓝字与竖杠。
    ///
    /// ⚠️ 不走差量「就地重配整份」：播放态每切一次歌都来，
    /// 可见行刷新就够。
    func refreshVisiblePlaybackState() {
        let chrome = viewModel.playbackChromeNow
        let selecting = viewModel.isSelectingNow
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let id = dataSource.itemIdentifier(for: indexPath),
                  let row = rowsByID[id],
                  let cell = tableView.cellForRow(at: indexPath) as? SongTableCell
            else { continue }
            cell.show(
                row,
                accessory: .menu(actionsController.makeRowActions(for: row)),
                isCurrent: chrome.isCurrent(id),
                isPlaying: chrome.isActuallyPlaying,
                isSelecting: selecting
            )
        }
    }

    // MARK: - 同页协作者的取数口

    /// 预取用：这些行现在的封面路径（不在表里就不给）。
    func artworkPaths(at indexPaths: [IndexPath]) -> [String] {
        indexPaths.compactMap { indexPath -> String? in
            guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
            return rowsByID[id]?.artworkPath
        }
    }

    /// 这一份列表里全部行的 id（按画面顺序）—— 全选 / 「添加到播放列表」用它。
    func allRowIDs() -> [Track.ID] {
        Array(dataSource.snapshot().itemIdentifiers)
    }

    func itemIdentifier(at indexPath: IndexPath) -> Track.ID? {
        dataSource.itemIdentifier(for: indexPath)
    }

    func indexPath(for id: Track.ID) -> IndexPath? {
        dataSource.indexPath(for: id)
    }

    // MARK: - 私有 · 数据源

    /// 建数据源 —— 行按 id 取内容，取的是一份**快照**（不是数组下标）。
    private func makeDataSource() -> SongListDataSource {
        let dataSource = SongListDataSource(tableView: tableView) { [weak self] tableView, indexPath, trackID in
            let dequeued = tableView.dequeueReusableCell(
                withIdentifier: SongTableCell.reuseIdentifier,
                for: indexPath
            )
            guard let self, let cell = dequeued as? SongTableCell, let row = self.rowsByID[trackID] else {
                assertionFailure("这一行必须是注册过的 SongTableCell，且它的歌必须还在当前列表里")
                return dequeued
            }
            cell.artworkProvider = self.artworkProvider
            // ⚠️ 「删除」这四个字**归动作协作者给**（见 `SongRowAction`）：行不知道这一页是曲库
            // 还是歌单，也就不知道这一项该叫「删除」还是「从歌单中移除」。
            let chrome = self.viewModel.playbackChromeNow
            cell.show(
                row,
                accessory: .menu(self.actionsController.makeRowActions(for: row)),
                isCurrent: chrome.isCurrent(trackID),
                isPlaying: chrome.isActuallyPlaying,
                isSelecting: self.viewModel.isSelectingNow
            )
            return cell
        }

        // 这个开关管的是**行自己**怎么出现 / 怎么消失，**不管**下面的行怎么补位
        // —— 补位是 `apply(_:animatingDifferences: true)` 那个开关的事。
        //
        // 所以这里实际只决定**新导入的歌怎么进来**：淡着出现。
        //
        // ⚠️ 别拿 `.none` 当"瞬间消失"用 —— Apple 文档里 `.none` 写的是
        // "The inserted or deleted rows use the default animations"（用默认动画），
        // 跟名字对不上。出处：developer.apple.com/documentation/uikit/uitableview/rowanimation
        dataSource.defaultRowAnimation = .fade

        // 索引条上划到某个字母 → 弹那个屏幕正中的气泡。
        dataSource.onIndexTitle = { [weak self] title in
            self?.indexBubble.show(title)
        }
        return dataSource
    }

    /// 快照 → 段。
    ///
    /// - 分段模式（按歌名）：交给 `SongSections` 按首字母分；
    /// - 其余情况：**一整段**，段名是空串（空串 = 不画段头、也不显示索引条）。
    ///
    /// - Parameter descending: 升序还是降序。**由调用方算一次传进来** ——
    ///   索引条（`applySections`）要用到同一个判断，"升还是降"只在一处读。
    private func makeSections(from snapshot: SongsViewModel.Snapshot, descending: Bool) -> [SongSections.Section] {
        guard snapshot.shouldGroup else {
            return [SongSections.Section(title: "", rows: snapshot.rows)]
        }
        return SongSections.group(snapshot.rows, descending: descending)
    }

    /// 把段灌进表格，并把索引条跟着调好。
    ///
    /// ⚠️ 段名当段 id：差量刷新按 id 认段，所以排序一变（段的集合整个换掉）本来就该整块重建。
    ///
    /// - Parameter descending: 索引条要不要跟着反 —— 降序时段的先后是反的，
    ///   索引条也得反，两边的方向才一致（`SongSections.indexTitles(descending:)`）。
    /// - Parameter reconfiguring: 行**还在、内容变了**的那些 id（换了封面 / 改了标签）——
    ///   请表格把它们就地重画一遍。差量刷新只认"行有没有增减"，内容变了自己不会重画。
    private func applySections(
        _ sections: [SongSections.Section], descending: Bool, reconfiguring: Set<Track.ID>
    ) {
        var diffable = NSDiffableDataSourceSnapshot<String, Track.ID>()
        diffable.appendSections(sections.map(\.title))
        for section in sections {
            diffable.appendItems(section.rows.map(\.id), toSection: section.title)
        }

        // ⚠️ 只重画**确实还在这一次快照里**的那些：传进来的集合是照着新列表算的，
        // 但同一瞬间可能有行被移走 —— 对着一个不在快照里的 id 重画会直接崩。
        // ⚠️ 必须在 `apply` **之前**写进快照 —— 这是"随这一次刷新一起生效"的意思。
        let present = Set(diffable.itemIdentifiers)
        let targets = reconfiguring.intersection(present)
        if !targets.isEmpty { diffable.reconfigureItems(Array(targets)) }

        dataSource.apply(diffable, animatingDifferences: true)

        // 段名非空 = 这是分段模式（哪怕只分出一段，也该显示索引条）。
        let isGrouped = !(sections.first?.title.isEmpty ?? true)
        dataSource.indexTitles = isGrouped ? SongSections.indexTitles(descending: descending) : []
        // ⚠️ 差量刷新不会自己重问"索引条显示什么"（那是 `reloadData` 干的事）——
        // 改完索引条内容要请它重新取一次，不然切换排序方式后索引条会留在原地。
        tableView.reloadSectionIndexTitles()

        if !isGrouped { indexBubble.hide() }
    }
}

// MARK: - 点一行 / 取消点行

extension SongsListController: UITableViewDelegate {

    /// 点一行 —— 三种走法，看是不是在选择模式、是不是正在播这一首：
    ///
    /// - **非选择 · 正在播这首**：打开播放页。
    /// - **非选择 · 其它**：播这一首（切歌 / 开播）。播完立刻取消高亮 ——
    ///   不取消的话这一行会一直亮着（没有任何地方会去取消它）。
    /// - **选择模式**：点一行 = 选中（勾）。
    ///
    /// 🔴 非选择那一支用**穷举 `switch`**、不用 `if case`：少写一个分支就是
    /// "用户点了没反应、还查不出错"（静默失败）。穷举着写，将来加 case 编译器会拦住。
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }

        if !viewModel.isSelectingNow {
            switch viewModel.handleRowTap(id: id) {
            case .presentNowPlaying:
                router.presentNowPlaying()
            case .missingFile:
                MissingFileNotice.show()
            case .startPlayback:
                break
            }
            tableView.deselectRow(at: indexPath, animated: true)
            return
        }

        viewModel.setSelected(id, true)
    }

    /// 勾被取消时同步 ViewModel —— 只可能发生在编辑模式。
    ///
    /// ⚠️ **程序化取消勾不会走到这儿**：`deselectRowAtIndexPath:` 头文件明说它
    /// "will not call the delegate methods"（表格勾的同步在 `TableSelectionSync`，用的就是它，
    /// 上面"播完取消高亮"也是程序化的），所以这个方法管的纯粹是**用户自己点掉**的那一路。
    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        viewModel.setSelected(id, false)
    }
}

// MARK: - 滚动 → 定位钮露 / 藏

extension SongsListController {

    /// 这三个回调跟着 `UITableViewDelegate` 走（一个 delegate 一个对象），再转给定位钮。
    ///
    /// ⚠️ 显式 `@objc`：可选 ObjC 协议方法必须保证那层 ObjC 暴露在，
    /// 否则 UIKit 的 `responds(to:)` 为假——滑了没回调。
    @objc func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        locatorController?.userBeganScrolling()
    }

    @objc func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            locatorController?.scrollDidSettle()
        }
    }

    @objc func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        locatorController?.scrollDidSettle()
    }
}
