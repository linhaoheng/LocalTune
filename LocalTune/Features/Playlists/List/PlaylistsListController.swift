import UIKit

/// 歌单列表的两段 —— **恒两段**：段 0 是「最爱的歌曲」（0 或 1 行），段 1 是用户歌单。
///
/// ⚠️ 两段**都不给段头**：它们是**结构**，不是给用户看的标题 ——
/// 「最爱的歌曲」那几个字写在那一行自己身上（见 `PlaylistRow.title`）。
enum PlaylistsSection {
    case favorites
    case users
}

/// 歌单页**列表协作者** —— 怎么分段、怎么拖、怎么画一行、快照怎么落表，都在这儿。
///
/// 页面私有协作者：两段列表内容（`favoriteRow` / `userRows`）跟行走在这儿。
/// 行上的五个动作经 `actionsController` 出去、添加模式经 `addingController` 出去，
/// 都是页面装配时接好的（见 `PlaylistsViewController`）。
///
/// ## 🔴 这一页为什么**不用差量数据源**（曲库页用的是它）
///
/// 两页要的东西不一样：
/// - **曲库页**一次可能进来几百首歌、排序随时变 —— 差量刷新省下的是"整表重画"，值；
/// - **歌单页**总共几十个歌单，而且它有一个曲库页没有的动作：**手动拖拽排序**。
///   拖拽恰好踩在差量数据源的短板上 —— 用户拖动是**表格自己**做的，数据源那份快照
///   不会跟着动（它只在 `apply` 的时候才知道顺序）。想同步就得在 `moveRowAt` 里再 `apply` 一次，
///   而那一下是在表格的编辑事务中间 —— 那是"在批量更新里再开一次批量更新"。
///
/// 几十行的一屏，`reloadData()` 本来就是零成本；而"顺序只有一份、就是 `userRows`"
/// 让拖拽这件事变得没有第二种可能。**所以这一页用普通数据源，是挑过的，不是漏了。**
@MainActor
final class PlaylistsListController: NSObject {

    // MARK: - 依赖

    private let viewModel: PlaylistsViewModel

    /// 点一行进歌单详情页 —— 跳转只从 `AppRouter` 出去。
    private let router: AppRouter

    /// 取图的动作 —— 装配层（`App/AppArtwork.image`）经页面递进来，配行时挂到行上。
    private let artworkProvider: ArtworkProvider

    private unowned let tableView: UITableView

    // MARK: - 同页协作者（页面装配时接上，比生命周期短不了）

    /// 行上五个动作（换封面 / 生成封面 / 改名 / 加入歌单 / 删除）的归处。
    weak var actionsController: PlaylistsActionsController?

    /// 添加模式（歌曲页多选进来）的归处；普通歌单页没有它。
    weak var addingController: PlaylistsAddingTracksController?

    // MARK: - 状态

    /// 列表内容 —— **两段各一份**，段 0 是「最爱的歌曲」（0 或 1 行），段 1 是用户歌单。
    ///
    /// 🔴 这是**唯一**一份列表内容：表格每次刷新都照着它重画（`reloadData()`）。
    /// 手动排序拖的是 `userRows` 这一个数组 —— 不存在"表格里一份、别处又一份"。
    ///
    /// ⚠️ `userRows` 是 `internal`：「完成」写回顺序时读的就是它（见
    /// `PlaylistsActionsController.finishManualSorting`）—— 它就是用户眼前那个顺序。
    private(set) var favoriteRow: PlaylistRow?
    var userRows: [PlaylistRow] = []

    init(
        viewModel: PlaylistsViewModel,
        tableView: UITableView,
        router: AppRouter,
        artworkProvider: @escaping ArtworkProvider
    ) {
        self.viewModel = viewModel
        self.tableView = tableView
        self.router = router
        self.artworkProvider = artworkProvider
        super.init()
        // 表格的两个角色在构造时认领 —— 挂接和"这个对象存在"是同一件事，
        // 装配方没有"建了它、忘了挂"的机会。
        tableView.dataSource = self
        tableView.delegate = self
    }

    // MARK: - 快照落表

    /// 列表内容换了 —— 两段换掉，请表格重画。
    func apply(_ snapshot: PlaylistsViewModel.Snapshot) {
        // 🔴 手动排序中**不重画**：那会儿 `userRows` 是用户**拖出来的**顺序，
        // 而快照推来的还是库里旧的顺序 —— 照着它重画，用户正拖着的行会当场跳回去。
        guard !viewModel.isReorderingNow else { return }

        favoriteRow = snapshot.favorites
        userRows = snapshot.users
        tableView.reloadData()
    }

    /// 两段的先后 —— **段号由它定**，别处不写死 0 / 1。
    ///
    /// ⚠️ 是 `static`：这是个常量，跟哪一页实例无关。
    private static let sections: [PlaylistsSection] = [.favorites, .users]
}

// MARK: - 数据源

extension PlaylistsListController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        Self.sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Self.sections[section] {
        case .favorites: return favoriteRow == nil ? 0 : 1
        case .users: return userRows.count
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let dequeued = tableView.dequeueReusableCell(
            withIdentifier: PlaylistTableCell.reuseIdentifier,
            for: indexPath
        )
        guard let cell = dequeued as? PlaylistTableCell, let row = row(at: indexPath) else {
            assertionFailure("这一行必须是注册过的 PlaylistTableCell，且它的歌单必须还在当前列表里")
            return dequeued
        }
        cell.artworkProvider = artworkProvider
        if let adding = addingController {
            adding.showAddingCell(cell, row: row)
        } else {
            cell.show(
                row,
                onChangeCover: { [weak actionsController] in actionsController?.changeCover(row) },
                onGenerateCover: { [weak actionsController] in actionsController?.generateCover(row) },
                onRename: { [weak actionsController] in actionsController?.rename(row) },
                onAddToPlaylist: { [weak actionsController] in actionsController?.addToPlaylist(row) },
                onDelete: { [weak actionsController] in actionsController?.confirmDelete(row) }
            )
        }
        return cell
    }

    // MARK: - 拖拽（手动排序）

    /// **只有用户歌单那一段能拖** —— 「最爱的歌曲」不参与手动排序（它永远在最上面）。
    ///
    /// 🔴 「哪几行能拖」这件事**只说一次**（就这一处）。参考实现用了四个方法互相兜
    /// （能不能编辑 / 编辑样式 / 能不能拖 / 编辑时缩不缩进），改一个忘一个的结果就是
    /// "某一行突然能拖了"。编辑态另外那几件全在下面 `UITableViewDelegate` 那一段里。
    ///
    /// ⚠️ 两段的分法是**协议定的**，不是随手摆的：`canMoveRowAt` / `moveRowAt` 是
    /// **数据源**方法，`editingStyleForRowAt` / `shouldIndentWhileEditingRowAt` 是**委托**方法。
    /// 放错文件**不会报错** —— 那个方法不会 `@objc` 出去，UIKit 根本看不见，静默不生效。
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        Self.sections[indexPath.section] == .users
    }

    /// 拖完一行 —— 把**那一份顺序**跟着改掉。
    ///
    /// ⚠️ 表格自己已经把那一行挪过去了（动画都演完了），这里只要把我们的数组对上，
    /// **不用**再 `reloadData()` —— 重画一遍等于把刚演完的动画又擦掉重来。
    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard Self.sections[sourceIndexPath.section] == .users,
              Self.sections[destinationIndexPath.section] == .users,
              userRows.indices.contains(sourceIndexPath.row) else { return }

        let moved = userRows.remove(at: sourceIndexPath.row)
        userRows.insert(moved, at: min(destinationIndexPath.row, userRows.count))
    }

    // MARK: - 取一行

    /// 这一行是哪个歌单。
    private func row(at indexPath: IndexPath) -> PlaylistRow? {
        switch Self.sections[indexPath.section] {
        case .favorites:
            return favoriteRow
        case .users:
            return userRows.indices.contains(indexPath.row) ? userRows[indexPath.row] : nil
        }
    }
}

// MARK: - 点一行 / 编辑态（手动排序）

extension PlaylistsListController: UITableViewDelegate {

    /// 点一行 —— 进那个歌单的详情页。
    ///
    /// 🔴 **编辑态（手动排序）里不跳**：那会儿整行的用途是**被拖**，
    /// 点一下是"抓住它"的前半程 —— 跳走的话顺序就白拖了。
    ///
    /// ⚠️ 跳转只从 `AppRouter` 出去，页面自己不 `push`。
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // 点完就把高亮收掉 —— 这一行不是"选中"，是"按了一下"。
        tableView.deselectRow(at: indexPath, animated: true)
        guard !tableView.isEditing, let row = row(at: indexPath) else { return }
        if let adding = addingController {
            adding.addSelectedTracks(to: row)
        } else {
            router.pushPlaylistDetail(id: row.id)
        }
    }

    /// 编辑态里每一行的**编辑样式**：都没有。
    ///
    /// 🔴 这一页的编辑态只用来拖拽，不是用来滑删的。系统默认是 `.delete` ——
    /// 不挡的话，一进编辑态每一行左边都会冒出一个红减号。
    ///
    /// ⚠️ 这个决定**只能**从这儿给：`UITableViewCell.editingStyle` 是**只读**属性，
    /// 设在行身上编译不过。
    func tableView(
        _ tableView: UITableView,
        editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        .none
    }

    /// 编辑态里内容**不缩进** —— 系统默认会往右推，给那个红减号腾地方，而我们根本没有红减号。
    ///
    /// ⚠️ 不放在行身上（`UITableViewCell.shouldIndentWhileEditing` 也能设）：
    /// 那两处答的是**同一个问题**，留两个出处，早晚有一个是摆设。这条在这儿生效，就只写这儿。
    func tableView(
        _ tableView: UITableView,
        shouldIndentWhileEditingRowAt indexPath: IndexPath
    ) -> Bool {
        false
    }

    /// 拖拽**不许跨段** —— 落点一律钳到用户歌单那一段。
    ///
    /// ⚠️ 不做这一步的话，用户能把一行拖到「最爱的歌曲」上面去 ——
    /// 那一段是恒 0/1 行的，落在那儿没有对应的位置，看着就是"松手之后行弹回去了"。
    func tableView(
        _ tableView: UITableView,
        targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath,
        toProposedIndexPath proposedDestinationIndexPath: IndexPath
    ) -> IndexPath {
        let usersSection = Self.sections.firstIndex(of: .users) ?? 0
        guard !userRows.isEmpty else { return IndexPath(row: 0, section: usersSection) }
        guard proposedDestinationIndexPath.section == usersSection else {
            return IndexPath(row: 0, section: usersSection)
        }
        let row = min(max(proposedDestinationIndexPath.row, 0), userRows.count - 1)
        return IndexPath(row: row, section: usersSection)
    }
}
