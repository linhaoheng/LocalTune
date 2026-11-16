import UIKit

/// 歌单详情页**列表协作者** —— 画行、点行、拖拽、选择模式下的勾；标题排序时分段 + 字母索引。
///
/// 页面私有协作者：列表内容只存**一份** —— `sections`（段 + 段内行）。
/// 平铺顺序 `songs`、右缘索引条 `indexTitles` 都由它**派生**，不另存。
///
/// ## 🔴 这一页为什么**不用差量数据源**
///
/// 这一页有拖拽手动排序，而**表视图那套差量数据源根本不认拖拽** —— 它的 `reorderingHandlers`
/// 只挂在 `UICollectionViewDiffableDataSource` 上（`UITableViewDiffableDataSource` 压根没这个成员），
/// 想同步顺序只能在 `moveRowAt` 里再 `apply` 一次＝"批量更新里再开批量更新"
///（跟歌单列表页同一条理由）。
///
/// 所以落表用普通 `UITableViewDataSource`；**「删除」那一档行级动画**另行补在 `apply` 里
///（识别"纯删除" → `deleteRows`），其余照旧整表重画。分段仍用普通数据源多段。
///
/// **一个 tableView 一个 delegate 对象**：`UITableViewDelegate`（点行 / 滚动）也归这里 ——
/// 滚动那几个回调转给定位钮协作者。
@MainActor
final class PlaylistDetailListController: NSObject {

    // MARK: - 依赖

    private let viewModel: PlaylistDetailViewModel

    /// 跳转 —— 点一行打开播放页（只从 `AppRouter` 出去）。
    private let router: AppRouter

    private let artworkProvider: ArtworkProvider

    private unowned let tableView: UITableView

    /// 索引条按下时、屏幕正中那个气泡（零件归页面装配，显示归这里）。
    private unowned let indexBubble: IndexBubble

    /// 行尾「更多」菜单里那几个动作的归处。
    private unowned let actionsController: PlaylistDetailActionsController

    /// 滚动回调的归处（定位钮本体在那边）。
    private weak var locatorController: PlaylistDetailPlayingLocatorController?

    // MARK: - 状态

    /// 当前列表里的行 —— **唯一一份**列表内容：段 + 段内行。
    ///
    /// 🔴 顺序只存这一处。手动排序拖的就是它（那时列表是平铺的一段），
    /// 所以「表格上显示的那份」和「查一行时读的那份」永远是同一个值 ——
    /// 不存在「两份各走各的、退编辑态那一下读岔」的窗口。
    private(set) var sections: [SongSections.Section] = []

    /// 屏幕上从上到下的行 —— 由 `sections` 摊平**派生**，不另存。
    ///
    /// ⚠️ 同页协作者只读：排序写回、全选、封面流条目都从这份拿。
    var songs: [SongRow] { sections.flatMap(\.rows) }

    /// 右缘索引条字母（空 = 不显示）。
    ///
    /// 只有**按标题分段**时才有：那会儿段名就是字母。别的排法是平铺一段，不给条。
    private var indexTitles: [String] {
        guard isLetterSectioned else { return [] }
        return SongSections.indexTitles(descending: viewModel.sortDirection == .descending)
    }

    /// 现在是不是按字母分段 —— 段名就是字母（平铺那一段段名为空）。
    private var isLetterSectioned: Bool {
        sections.contains { !$0.title.isEmpty }
    }

    init(
        viewModel: PlaylistDetailViewModel,
        tableView: UITableView,
        router: AppRouter,
        artworkProvider: @escaping ArtworkProvider,
        indexBubble: IndexBubble,
        actionsController: PlaylistDetailActionsController,
        locatorController: PlaylistDetailPlayingLocatorController
    ) {
        self.viewModel = viewModel
        self.tableView = tableView
        self.router = router
        self.artworkProvider = artworkProvider
        self.indexBubble = indexBubble
        self.actionsController = actionsController
        self.locatorController = locatorController
        super.init()
        // 表格的两个角色在构造时认领 —— 挂接和"这个对象存在"是同一件事，
        // 装配方没有"建了它、忘了挂"的机会。
        tableView.dataSource = self
        tableView.delegate = self
    }

    // MARK: - 快照落表

    /// 列表内容换了 —— 分段、落表、索引条一起调好。
    ///
    /// - Returns: 这一份列表里全部行的 id（按画面顺序）—— 调用方拿它收拾选中集合。
    @discardableResult
    func apply(_ snapshot: PlaylistDetailViewModel.Snapshot) -> [Track.ID] {
        // 「升还是降」只读一次 —— 分段和索引条共用，避免段反了、条没反。
        let descending = viewModel.sortDirection == .descending
        let nextSections = snapshot.shouldGroup
            ? SongSections.group(snapshot.songs, descending: descending)
            : [SongSections.Section(title: "", rows: snapshot.songs)]

        // 🔴 只是「删掉了几行」的时候，让被删的那几行**淡出**、下面的行补上来（跟曲库页同一档观感）。
        // ⚠️ indexPath 得对着**改之前**的 `sections` 算 —— 表格那一刻还是旧状态。
        // ⚠️ 顺序不能反：**先落表、再 `deleteRows`**。`deleteRows` 会拿"数据源现在给的行数"
        // 跟"表格自己记的行数"对账，两者差得正好是被删的那几行才算合法；反过来先掉行数就直接崩。
        let previous = sections
        let removedPaths = removalIndexPaths(from: previous, to: nextSections)
        sections = nextSections

        // 分段用了系统 collation，顺序可能和 `PlaylistDetailSort` 不一致 —— 播放队列跟画面走。
        let visibleIDs = songs.map(\.id)
        viewModel.syncPlayOrder(toVisibleIDs: visibleIDs)

        if let removedPaths {
            tableView.deleteRows(at: removedPaths, with: .fade)
        } else if previous != nextSections {
            // 🔴 内容**一模一样**就不重画 —— 这是必需的，不是省事：
            // 删掉一首「已收藏」的歌会让「歌单成员」和「收藏」**两个来源各推一次**
            //（`combineLatest` 收到两次），第二次的内容和第一次完全相同。
            // 那一下再 `reloadData()`，就把刚演到一半的删除动画擦掉了。
            tableView.reloadData()
        }
        tableView.reloadSectionIndexTitles()
        if !isLetterSectioned { indexBubble.hide() }

        return visibleIDs
    }

    /// 播放态变了 / 进出多选 —— 只重配**屏幕上看得见的行**。
    func refreshVisiblePlaybackState() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let row = song(at: indexPath),
                  let cell = tableView.cellForRow(at: indexPath) as? SongTableCell
            else { continue }
            configure(cell, row: row)
        }
    }

    // MARK: - 行查找

    /// 当前 indexPath 对应的行 —— 画面顺序只有一份，**不看模式**。
    func song(at indexPath: IndexPath) -> SongRow? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].rows.indices.contains(indexPath.row)
        else { return nil }
        return sections[indexPath.section].rows[indexPath.row]
    }

    /// 某首歌在当前列表里的位置（定位钮 / 勾选用）—— 同样只看这一份顺序。
    func indexPath(forTrackID id: Track.ID) -> IndexPath? {
        for (section, group) in sections.enumerated() {
            if let row = group.rows.firstIndex(where: { $0.id == id }) {
                return IndexPath(row: row, section: section)
            }
        }
        return nil
    }

    /// 滚到某首歌（封面流出流时对齐中央那一首）。
    ///
    /// ⚠️ 默认 `.middle` + 不带动画 —— 出流是揭罩那一下完成的，滚表不能有可见动画。
    func scrollToSong(
        id: Track.ID,
        position: UITableView.ScrollPosition = .middle,
        animated: Bool = false
    ) {
        guard let path = indexPath(forTrackID: id) else { return }
        tableView.scrollToRow(at: path, at: position, animated: animated)
    }

    // MARK: - 私有

    /// 这一次变化如果**只是删掉了几行**，给出那几行**改之前**的 `indexPath`；其余情形给 `nil`。
    ///
    /// 三个条件同时成立才算 —— 段名序列一个没动、没有新行、确实少了行。
    /// 别的情形（增删混在一起 / 段增减 / 只是换了顺序）一律交给 `reloadData()` 整表重画：
    /// 想把它们也做成行级动画，就得自己算增、删、移三样，那是另起一套差量引擎；
    /// 而表视图那套现成的差量数据源又不认拖拽（手动排序要用它）。
    /// 权衡下来「删除淡出、其余重画」这一档最划算，也正好是用户看得到的那个差别。
    ///
    /// ⚠️ 段名相同就够，**不需要段数也相同** —— 某一段被删空是合法的（系统照常画那个空段）。
    ///
    /// ⚠️ `indexPath` 必须对着**改之前的**那一份算：那正是表格当下的状态。
    private func removalIndexPaths(
        from old: [SongSections.Section],
        to new: [SongSections.Section]
    ) -> [IndexPath]? {
        guard old.map(\.title) == new.map(\.title) else { return nil }

        let oldIDs = Set(old.flatMap { $0.rows.map(\.id) })
        let newIDs = Set(new.flatMap { $0.rows.map(\.id) })
        // 「纯删除」＝ 新的那些全都还在旧的里，而且确实少了几行。
        guard newIDs.isSubset(of: oldIDs), newIDs.count < oldIDs.count else { return nil }

        return old.enumerated().flatMap { section, group in
            group.rows.enumerated().compactMap { row, song -> IndexPath? in
                newIDs.contains(song.id) ? nil : IndexPath(row: row, section: section)
            }
        }
    }

    private func configure(_ cell: SongTableCell, row: SongRow) {
        let selecting = viewModel.isSelectingNow
        let reordering = viewModel.isReorderingNow
        let chrome = viewModel.playbackChromeNow

        let accessory: SongRowAccessory
        if reordering {
            accessory = .none
        } else {
            accessory = .menu(actionsController.makeRowActions(row))
        }

        cell.show(
            row,
            accessory: accessory,
            isCurrent: chrome.isCurrent(row.id),
            isPlaying: chrome.isActuallyPlaying,
            isSelecting: selecting || reordering
        )
    }
}

// MARK: - 数据源

extension PlaylistDetailListController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        // 手动排序时列表本来就是平铺的一段（进编辑态前排序字段已切回「歌单顺序」），
        // 不必再为它单独判一段。
        max(sections.count, 1)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard sections.indices.contains(section) else { return 0 }
        return sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard sections.indices.contains(section), !sections[section].title.isEmpty else { return nil }
        return sections[section].title
    }

    func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        indexTitles.isEmpty ? nil : indexTitles
    }

    func tableView(
        _ tableView: UITableView,
        sectionForSectionIndexTitle title: String,
        at index: Int
    ) -> Int {
        indexBubble.show(title)
        let among = sections.map(\.title).filter { !$0.isEmpty }
        return SongSections.sectionIndex(forIndexTitle: title, among: among)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let dequeued = tableView.dequeueReusableCell(
            withIdentifier: SongTableCell.reuseIdentifier,
            for: indexPath
        )
        guard let cell = dequeued as? SongTableCell, let row = song(at: indexPath) else {
            assertionFailure("这一行必须是注册过的 SongTableCell，且它的歌必须还在当前列表里")
            return dequeued
        }
        cell.artworkProvider = artworkProvider
        configure(cell, row: row)
        return cell
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        viewModel.isReorderingNow
    }

    func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        // 拖拽只可能在手动排序里（见 `canMoveRowAt`）—— 那时列表是平铺的一段。
        guard sections.count == 1 else {
            assertionFailure("手动排序时列表应当是平铺的一段")
            return
        }
        guard sections[0].rows.indices.contains(sourceIndexPath.row) else { return }

        var rows = sections[0].rows
        let moved = rows.remove(at: sourceIndexPath.row)
        rows.insert(moved, at: min(max(destinationIndexPath.row, 0), rows.count))
        sections[0] = SongSections.Section(title: sections[0].title, rows: rows)
    }
}

// MARK: - 点一行 / 编辑态

extension PlaylistDetailListController: UITableViewDelegate {

    func tableView(
        _ tableView: UITableView,
        editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        .none
    }

    func tableView(
        _ tableView: UITableView,
        shouldIndentWhileEditingRowAt indexPath: IndexPath
    ) -> Bool {
        // 选择模式要缩进出勾；手动排序不缩进（只露拖柄）。
        viewModel.isSelectingNow
    }

    func tableView(
        _ tableView: UITableView,
        targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath,
        toProposedIndexPath proposedDestinationIndexPath: IndexPath
    ) -> IndexPath {
        guard !songs.isEmpty else { return IndexPath(row: 0, section: 0) }
        let row = min(max(proposedDestinationIndexPath.row, 0), songs.count - 1)
        return IndexPath(row: row, section: 0)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let row = song(at: indexPath) else { return }
        let id = row.id

        if viewModel.isReorderingNow {
            tableView.deselectRow(at: indexPath, animated: false)
            return
        }

        if viewModel.isSelectingNow {
            viewModel.setSelected(id, true)
            return
        }

        tableView.deselectRow(at: indexPath, animated: true)
        // 🔴 穷举 `switch`（同曲库页）：少写一个分支就是"点了没反应、还查不出错"。
        switch viewModel.handleRowTap(id: id) {
        case .presentNowPlaying:
            router.presentNowPlaying()
        case .missingFile:
            MissingFileNotice.show()
        case .startPlayback:
            break
        }
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard viewModel.isSelectingNow, let row = song(at: indexPath) else { return }
        viewModel.setSelected(row.id, false)
    }
}

// MARK: - 滚动 → 定位钮露 / 藏

extension PlaylistDetailListController {

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
