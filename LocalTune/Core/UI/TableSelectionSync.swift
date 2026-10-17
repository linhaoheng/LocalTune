import UIKit

// MARK: - 表格选中态的机制

/// 「哪一行是哪一位」—— 由各页的 diffable 数据源回答，机制不认识任何业务。
///
/// 🔴 `ID` 是**泛型**，不是某个业务类型：这个文件住在 `Core/`，按宪法 §一 六层
/// **不许知道「歌曲」「歌单」这类词** —— 它只认识「行 ↔ 某个编号」这个通用概念。
/// 谁用谁填：曲库页填 `Track.ID`，将来别的列表填它自己的编号。
struct TableSelectionDirectory<ID: Hashable> {

    /// 这一行是谁（没有 ＝ `nil`，比如已经滚出快照的行）。
    let idAt: (IndexPath) -> ID?

    /// 这个 id 在第几行（找不到 ＝ `nil`）。
    let indexPathFor: (ID) -> IndexPath?
}

/// 表格选中态 ↔ id 集合的**双向对齐** —— 机制全工程一份。
///
/// 🔴 **判据不进这儿**：「哪些 id 该被选着」永远在调用方（VM 的选中集合）。
/// 这里只做「把表格的勾对成给定的集合」这一件机械事。
/// 🔴 **`@MainActor`**：它伺候的 `SelectionState`（主隔离的 VM）和 `UITableView` 都只在主线程；
/// 调用方（两个 SelectionController）也是主隔离。
/// 见 `docs/设计/消重复设计.md` §3.3。
@MainActor
struct TableSelectionSync<ID: Hashable> {

    private let tableView: UITableView
    private let directory: TableSelectionDirectory<ID>

    init(tableView: UITableView, directory: TableSelectionDirectory<ID>) {
        self.tableView = tableView
        self.directory = directory
    }

    /// 把表格那边的勾**整体**设成这一组 id —— 程序化改动之后调（全选 / 取消全选 / 列表变了）。
    ///
    /// ⚠️ 用户自己点行时**不要**调这个：那条路上是表格先动的，再回头同步就是绕圈。
    func sync(to ids: Set<ID>) {
        let selectedIndexPaths = Set(tableView.indexPathsForSelectedRows ?? [])

        for indexPath in selectedIndexPaths {
            guard let id = directory.idAt(indexPath), !ids.contains(id) else { continue }
            tableView.deselectRow(at: indexPath, animated: false)
        }

        for id in ids {
            guard let indexPath = directory.indexPathFor(id) else { continue }
            guard !selectedIndexPaths.contains(indexPath) else { continue }
            tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
        }
    }

    /// 摘掉所有勾。
    func deselectAll() {
        tableView.indexPathsForSelectedRows?.forEach {
            tableView.deselectRow(at: $0, animated: false)
        }
    }

    /// 列表换了之后收拾一遍选中集合：先 prune 状态、再对勾。
    ///
    /// ⚠️ **顺序不能反**：先落状态（VM 那边的集合可能缩小），再 sync ——
    /// 同步得让表格对成**新的**集合。
    ///
    /// 🔴 `State` 用**泛型参数**、不用 `any SelectionState`：带着关联类型的协议当存在类型用，
    /// 调用方还得把关联类型擦一遍；泛型参数让「状态的编号」和「表格的编号」当场对上
    /// （`where State.ID == ID`），写不出「拿 A 页的选中集合去对 B 页的表格」这种组合。
    func prune<State: SelectionState>(to available: [ID], state: State) where State.ID == ID {
        state.pruneSelection(to: available)
        guard state.isSelectingNow else { return }
        sync(to: state.selectedIDsNow)
    }
}

// MARK: - 多选状态的读口

/// 多选状态的三个读口 —— 曲库 / 歌单详情两个 VM 同一形状。
///
/// 🔴 **立约不立真相**：两个 VM 各自读写自己的选中集（那是**两份独立状态**，
/// 形状相同 ≠ 重复，见设计文档 §二）；这里只把它们能被机制收拾的口子立下来。
/// 🔴 **`@MainActor`**：实现方（两个 VM）都是主隔离，协议不标遵循就跨隔离。
/// 🔴 `ID` 是关联类型：`Core/` 不许把某个业务编号写死（见文件顶上那条）。
@MainActor
protocol SelectionState: AnyObject {
    associatedtype ID: Hashable

    /// 丢掉已经不在列表里的选中项。
    func pruneSelection(to available: [ID])
    var isSelectingNow: Bool { get }
    var selectedIDsNow: Set<ID> { get }
}

// MARK: - prune 的数学

/// 多选 prune 的数学 —— 纯函数，只此一份（两个 VM 曾经逐字各抄一遍）。
enum SelectionMath {

    /// 丢掉**已经不在列表里**的选中项，返回留下的集合。
    ///
    /// ⚠️ 必须做：搜索条件一变，先前选中的歌可能已经看不见了 ——
    /// 不清理的话「删除」会作用到用户根本没在看着的歌上。
    /// 「值没变就不写」的纪律**不在**这儿 —— 那是各 VM 写侧的事。
    static func prune<ID: Hashable>(_ selected: Set<ID>, to available: [ID]) -> Set<ID> {
        selected.intersection(Set(available))
    }
}
