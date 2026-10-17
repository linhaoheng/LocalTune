import UIKit

/// 「添加歌曲到歌单」页**列表这一块** —— 怎么画一行、点一行之后干什么、快照怎么落表。
///
/// 页面私有协作者：页面只负责装配和订阅，这里持有列表自己的状态（`songs` / `selectedIDs` /
/// `drawn`）并把订阅结果落到表上 —— 状态跟行为走，不回头看页面的东西。
///
/// ## 🔴 这一页为什么**不用差量数据源**（曲库页用的是它）
///
/// 跟歌单详情页同一条理由：这一页没有拖拽、没有分段，**内容一变就是整份换**
/// ⇒ `reloadData()` 正好是它的语义，而且"数据变了界面还是旧的"这类问题在这儿不会出现。
/// （"勾一下"那一路不重载行，直接重新配置屏幕上的 cell —— 见下面的 `apply`。）
@MainActor
final class AddSongsListController: NSObject {

    // MARK: - 依赖

    private let viewModel: AddSongsViewModel

    /// 取图的动作 —— 装配层（`App/AppArtwork.image`）经页面递进来，配行时挂到行上。
    private let artworkProvider: ArtworkProvider

    private unowned let tableView: UITableView

    // MARK: - 状态

    /// 当前列表里的行 —— 配置行时按行号取。
    private var songs: [SongRow] = []

    /// 现在勾着哪些 —— 配置行时看它决定那一格画勾还是空圈。
    private var selectedIDs: Set<Track.ID> = []

    /// 上一份画出去的快照 —— 用来分辨"是列表换了"还是"只是勾变了"（见 `apply`）。
    private var drawn: AddSongsViewModel.Snapshot?

    init(
        viewModel: AddSongsViewModel,
        tableView: UITableView,
        artworkProvider: @escaping ArtworkProvider
    ) {
        self.viewModel = viewModel
        self.tableView = tableView
        self.artworkProvider = artworkProvider
        super.init()
        // 表格的两个角色在构造时认领 —— 挂接和"这个对象存在"是同一件事，
        // 装配方没有"建了它、忘了挂"的机会。
        tableView.dataSource = self
        tableView.delegate = self
    }

    // MARK: - 快照落表

    /// 列表内容换了。
    ///
    /// 🔴 **这里分两条路，是因为"勾一下"和"列表换了"完全是两件事**：
    /// - 行本身换了（搜索词变了、库动了）⇒ 整表重画；
    /// - 只是勾变了 ⇒ **只重新配置屏幕上受影响的行**。
    ///
    /// 勾一下不重载行：直接给可见 cell 重新配置，避免滚动位置、行布局和触摸事件被刷新动画打断。
    func apply(_ snapshot: AddSongsViewModel.Snapshot) {
        let previous = drawn
        drawn = snapshot
        songs = snapshot.songs
        selectedIDs = snapshot.selectedIDs

        // ⚠️ 比的是**整个 id 序列**、不是集合：顺序也变了的话（排序/过滤方式换过），
        // 光刷那几行会留下一批"位置对不上"的行 —— 它们没被重画，还画着原来的内容。
        guard let previous, previous.songs.map(\.id) == snapshot.songs.map(\.id) else {
            tableView.reloadData()
            return
        }

        // 勾选态变了的是哪些 —— **对称差**：加上的、去掉的都在里面，一次算完。
        // ⚠️ 它可能带上"当前列表里根本没有"的 id（被搜索筛掉的）—— 下面按 `songs` 过一遍
        // 自然就把它们滤掉了，不用再拦一次。
        let changed = previous.selectedIDs.symmetricDifference(snapshot.selectedIDs)
        guard !changed.isEmpty else { return }

        // 重新配置 cell，不启动 UITableView 的行刷新动画。
        // 不在屏幕上的行留给 cellForRowAt；它下次出现时会按最新 selectedIDs 配置。
        for indexPath in songs.indices
            .filter({ changed.contains(songs[$0].id) })
            .map({ IndexPath(row: $0, section: 0) }) {
            guard let cell = tableView.cellForRow(at: indexPath) as? SongTableCell else { continue }
            let row = songs[indexPath.row]
            cell.show(row, accessory: .selection(isSelected: selectedIDs.contains(row.id)))
        }
    }
}

// MARK: - 数据源

extension AddSongsListController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        songs.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let dequeued = tableView.dequeueReusableCell(
            withIdentifier: SongTableCell.reuseIdentifier,
            for: indexPath
        )
        guard let cell = dequeued as? SongTableCell, songs.indices.contains(indexPath.row) else {
            assertionFailure("这一行必须是注册过的 SongTableCell，且它的歌必须还在当前列表里")
            return dequeued
        }
        let row = songs[indexPath.row]
        cell.artworkProvider = artworkProvider
        // SongTableCell 默认服务曲库页和歌单详情页；挑歌页让系统默认表面透出来。
        cell.backgroundColor = .clear
        cell.show(row, accessory: .selection(isSelected: selectedIDs.contains(row.id)))
        return cell
    }
}

// MARK: - 点一行

extension AddSongsListController: UITableViewDelegate {

    /// 点一行 = **勾 / 取消勾**（行的哪一部分都可以，包括行尾那枚勾选标记所在的位置 ——
    /// 它自己不吃点击，见 `SongTableCell.showAccessory`）。
    ///
    /// ⚠️ 这一页**不播歌** —— 它不是曲库页，是"从**这个歌单**的角度看整个曲库"：
    /// 用户在挑歌，手点下去的每一行都该是"要 / 不要"，而不是"现在开始放这首"
    ///（`didSelectRow` 也只做 toggle）。
    ///
    /// ⚠️ 勾完**立刻取消高亮**（`deselectRow`）：这一行不是"选中"，是按了一下。
    /// 高亮留着的话，用户分不清"亮着"和"勾上"哪个才算数。
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard songs.indices.contains(indexPath.row) else { return }
        viewModel.toggle(id: songs[indexPath.row].id)
    }
}
