import Foundation

/// 歌词正文的**横向对齐** —— 四档里我们只要三档。
///
/// 🔴 **为什么不直接用 `NSTextAlignment`**：这份偏好要落在 `AppSettings`（它只 `import Foundation`），
/// 存 `NSTextAlignment` 就等于给设置层引进来 UIKit；而且系统那个枚举还带着 `.justified` / `.natural`
/// 两个我们用不上的档 —— 存它就得在读写两头各写一遍"不认识的值落回哪一档"。
///
/// ⇒ 值层留一个 UIKit-free 的三档枚举，界面侧（`LyricsLineCell`）再翻成 `NSTextAlignment`。
///
/// ⚠️ **声明顺序 = 设置面板里从左到右的段序**（左 / 中 / 右）—— 面板是拿 `allCases` 建段的，
/// 别随手调换（分段控件的 index 也是 左0 / 中1 / 右2）。
enum LyricsAlignment: String, CaseIterable {

    case left
    case center
    case right
}

/// 歌词的**外观**：字号 ＋ 对齐 —— 一份值，设置面板与歌词列表之间就传这一整份。
///
/// 🔴 **为什么合成一个结构、而不是两个独立属性**：这两项永远是"一起读、一起写"的
/// （进播放页读一份、面板改完回写一份）。拆开就有两个"当前值"：面板打开时要读两次、
/// 回调时要写两次，而中间那一刻两份值还可能不同步。
///
/// ## 范围与默认值在这儿，不在界面里
///
/// `16…36` / 默认 `18`。
/// 🔴 **钳位写在 `init` 里**：任何一条路（读盘读到坏值 / 面板滑杆 / 将来别的入口）造出来的
/// 都一定落在范围内 —— 「合法值」这条不变量只该有一个出口。
struct LyricsAppearance: Equatable {

    let fontSize: CGFloat
    let alignment: LyricsAlignment

    /// 字号可选范围 —— **16…36**，**整数档、步进 1**。
    static let fontSizeRange: ClosedRange<CGFloat> = 16...36

    /// 默认字号 —— **18**（也是读盘读不到值时的兜底）。
    static let defaultFontSize: CGFloat = 18

    /// 出厂值：**18 号、居中**。
    ///
    /// ⚠️ 它跟 `AppMetrics.nowPlayingLyricsFontSize` 同值（都是 18）但**不是一回事**：
    /// 那一个是"歌词正文"的出厂字号常量（值层引不了 UIKit 那套令牌），
    /// 这一份是"用户偏好"的出厂值。空态占位固定吃前者、**不跟设置**。
    static let `default` = LyricsAppearance(fontSize: defaultFontSize, alignment: .center)

    /// 造一份**一定合法**的外观 —— 字号**先取整**、再越界就地钳进 `fontSizeRange`。
    ///
    /// 🔴 **取整为什么写在这儿**：字号只有整数档，
    /// 这条跟"落在范围内"一样是**值自己的约束** ⇒ 不变量只该有一个出口，
    /// 每个入口（读盘 / 滑杆 / 将来的别的入口）各写一遍 `rounded()` 迟早漏一个。
    init(fontSize: CGFloat, alignment: LyricsAlignment) {
        let size = fontSize.rounded()
        self.fontSize = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        self.alignment = alignment
    }
}
