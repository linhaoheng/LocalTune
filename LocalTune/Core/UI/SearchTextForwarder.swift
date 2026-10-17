import UIKit

/// 会吃搜索词的东西 —— 四个列表 VM 同一个口。
///
/// 方法早已同名同签名（`setSearchText(_:)`），这里只是**立约**。各 VM 用空扩展遵循。
/// 🔴 **`@MainActor`**：四个 VM 都是主隔离，协议不标的话遵循会「跨进主隔离」
///（现在是告警、Swift 6 就是错误）。转发器那边见 `updateSearchResults` 的注。
@MainActor
protocol SearchTextSetting: AnyObject {
    func setSearchText(_ text: String)
}

/// 搜索转发器 —— 「搜索框的字 → `SearchTextSetting`」的**唯一实现**。
///
/// 🔴 **为什么是个小对象而不是协议默认实现**：`UISearchResultsUpdating` 是 **@objc 协议**，
/// Swift 协议扩展的默认实现**满足不了** @objc 要求（typecheck 点名的那条）。
/// 于是「转发」不靠页面遵循协议，靠**把这个对象塞给 `searchResultsUpdater`** ——
/// 四个页面各一行装配，转发逻辑（取词、解包、转交）只此一份。
///
/// ⚠️ **页面必须持有它**：`searchResultsUpdater` 只持 `weak`，没人抱住它就悄悄释放、
/// 搜索静默失灵 —— 各页面一个 `searchForwarder` 存属性，见 `docs/设计/消重复设计.md` §3.2。
final class SearchTextForwarder: NSObject, UISearchResultsUpdating {

    private weak var target: SearchTextSetting?

    init(target: SearchTextSetting) {
        self.target = target
    }

    /// 搜索框里的字一变就调 —— 这里只转发，**过滤本身在 ViewModel 里**。
    ///
    /// 🔴 系统保证这个回调在**主线程**（`UISearchResultsUpdating` 的契约）⇒
    /// `assumeIsolated` 进主隔离去调 VM；不然 `@MainActor` 的协议够不着。
    nonisolated func updateSearchResults(for searchController: UISearchController) {
        MainActor.assumeIsolated {
            target?.setSearchText(searchController.searchBar.text ?? "")
        }
    }
}
