import SnapKit
import UIKit

/// 两个页面共用的**列表页脚统计条** —— 「12 首歌, 时间: 45:03」。
///
/// 挂法是 `tableView.tableFooterView`：**要滚到列表最底下才看得到**，不吸在屏幕底。
/// 列表空着时这行**只剩一块空白**，文字清掉、位置和高度都还在。
///
/// ## 🔴 位置归表格管，我们只管高度
///
/// `tableFooterView` 的 frame 是**分工**的：**位置**（落在内容末尾哪一行）和**宽度**
/// 由表格摆，我们唯一要告诉它的是**多高** —— 就是那个 frame 的高度。
///
/// ⚠️ 所以 `attach(to:)` 里那句给 frame 只发生在**挂上去之前**：那一刻表格还没摆过它、
/// 宽度也还没有，先给一个高度（`x` / `y` / `width` 随后都会被表格覆盖掉）。
///
/// 🔴 **挂上去之后别再动它的 frame。** 踩过：直接把 label 当 footer，挂上去那一刻它还是
/// 0 高（表格以为这条不存在），之后又手动把 frame 设成 `y: 0` —— 于是它作为表格的子视图
/// **钉在了可视区顶上**（导航栏下面、第一行的位置），而且滚动时不动。
/// ⇒ 那句话就封在 `attach(to:)` 里，外面没有第二个地方能碰它的 frame。
///
/// ⚠️ 只在**装的时候**赋一次 frame 就够（不用每次刷新都重挂）：拿 label 直接当
/// footer、宽度每次都在变，得请系统重算一遍；我们这层容器**高度是固定的**，表格每次布局
/// 自己会把它摆到内容末尾。
final class ListFooterView: UIView {

    /// 这一条自己的尺寸。
    ///
    /// ⚠️ 只有这一个地方用 ⇒ 不进 `AppMetrics`（那儿是按页面积累的间距档，没有这一档）。
    private enum Metrics {

        /// 左右各留多少。
        static let insetX = AppMetrics.s15

        /// 这条带子有多高。
        ///
        /// ⚠️ **不是"内容撑出来的"，是设计值**：它就是一条固定高的带子，字在里面居中。
        static let height: CGFloat = 45
    }

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 字号颜色在这儿定死，之后只管填字。
        label.textColor = AppColor.subtitle
        label.font = AppFont.songSubtitle

        addSubview(label)
        // 左右那点缩进只能由**容器里的约束**来管 —— 给 label 自己设 frame 会被表格冲掉
        //（表格只认容器，label 是容器的子视图）。
        label.snp.makeConstraints {
            $0.leading.trailing.equalToSuperview().inset(Metrics.insetX)
            $0.centerY.equalToSuperview()
        }
    }

    required init?(coder: NSCoder) {
        assertionFailure("界面全部用代码搭，不会从 xib / storyboard 解档")
        return nil
    }

    // MARK: - 对外

    /// 列表内容变了 —— 重新填这一行。
    ///
    /// - Parameters:
    ///   - count: 当前列表里有几首（搜索时就是搜到的那些）。
    ///   - totalDurationMs: 这些歌加起来多长。
    func show(count: Int, totalDurationMs: Int) {
        label.text = FooterText.summary(count: count, totalDurationMs: totalDurationMs)
    }

    /// 把这一行的字**清掉**（这条带子本身留着，只变成一块空白）。
    ///
    /// ⚠️ **什么时候该清是页面的决定，不是组件的**：曲库页空库时要清
    ///（页面正中已经摆着一句「您的音乐库中没有歌曲」，页脚再报一次是重复），
    /// 歌单详情页**空歌单时也清**（这一条很容易漏：
    /// 空列表就不出统计 —— 那儿没有"0 首歌"这种东西）。
    func clear() {
        label.text = nil
    }

    /// 把这条子挂到表格上。
    ///
    /// - Parameter tableView: 挂在它的 `tableFooterView` 上。
    func attach(to tableView: UITableView) {
        // ⚠️ 高度得在**挂上去之前**给好（表格只读这一刻的 frame 高度）；
        // 宽度只是个初值，挂上去之后表格会按表格宽度覆盖它。
        frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: Metrics.height)
        tableView.tableFooterView = self
    }
}

// MARK: - 文案

/// 底部统计那行字怎么拼。
private enum FooterText {

    /// 「12 首歌, 时间: 05:07」。
    ///
    /// ⚠️ 两个标点**故意用半角**：数字后面是**英文逗号加空格**、时间前面是英文冒号 ——
    /// 整行看起来才像一句"数据摘要"。别"顺手"统一成 `12 首歌，时间：05:07`（全角标点
    /// 配数字在里面会显得松、不像统计条）。
    ///
    /// 🔴 **数字和汉字之间留一个半角空格** —— `12 首歌`，不是 `12首歌`。
    /// 全工程统一：凡「数字摘要」式的文案（浮层「已导入 N 首」· 歌单行「N 首歌」·
    /// 删除确认「这 N 首歌吗？」）都留这个空格，让数字从汉字里跳出来。
    /// ⚠️ 这个空格**本来就在规格里**（`docs/参考/功能-参考项目映射.md` 的样例就是
    /// `"\(count) 首歌, 时间: …"`），我们先前是**漏了**。
    static func summary(count: Int, totalDurationMs: Int) -> String {
        "\(count) 首歌, 时间: \(durationText(totalDurationMs))"
    }

    /// 总时长 —— 分秒**一定两位**（`05:07`）；**满一小时才多出小时那一段**（`01:05:07`）。
    ///
    /// 🔴 **先算总秒数、再拆时分秒**：进来的毫秒是**已经加过一遍的**总量
    /// （见 VM 快照里的 `totalDurationMs`），这里只做一次取整。
    ///
    /// ⚠️ 和单曲时长（`Track.durationText`）**是两条规则，别互相改**：
    /// 单曲那边小时**不补零**（`1:05:07`），这条小时也补零（`01:05:07`）。
    /// 两者不在同一屏上见面，各自照各自的出处。
    static func durationText(_ totalDurationMs: Int) -> String {
        // 毫秒**四舍五入**到秒，不是截断 —— 58300 毫秒是 58.3 秒，报 00:58 是少报。
        // 负数和 0 只在数据坏掉时出现，夹到 0 让这行不至于显示成 "-1:-5"。
        let totalSeconds = max(0, Int((Double(totalDurationMs) / 1000).rounded()))
        let hours = totalSeconds / 3600
        let minutes = totalSeconds / 60 % 60
        let seconds = totalSeconds % 60
        guard hours > 0 else { return String(format: "%02d:%02d", minutes, seconds) }
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
