import UIKit

/// 字号真值层 —— 只回答「**有哪几号字**」，不回答「哪儿用哪一号」。
///
/// 三层：页面 → `AppFont`（语义）→ `FontScale`（本文件，真值）→ `UIFont.scaled(_:weight:)`（机制）。
///
/// 八档字号 × 字重按需组合，下面列一个清单。档位号 1 最大、8 最小，中间不跳档。
/// 下面写的都是**设计值**，实际渲染的字号由 `UIFont.scaled` 按系统文字大小缩放。
enum FontScale {

    /// 八档字号（设计值，pt）。1 最大、8 最小。
    ///
    /// ⚠️ 其中两档是**为单个组件加的**，不在版式原本那一组里：
    /// - `s1`（**24**）—— 索引条按下时屏幕正中那个气泡里的大字母；
    /// - `s8`（**8**）—— 列表行那枚音质徽章里那两个字（8 粗；
    ///   播放页那枚是 9 粗，走 `s7`）。
    ///   ⚠️ 为什么不能拿 `s7`（9）凑：**两枚徽章是两个字号**，而列表行那枚旁边还站着
    ///   一个 9pt 的格式标记 —— 徽章用 9 就跟它一样大了，"徽章比格式标记小一号"那点层次会没掉。
    enum Step: CGFloat {
        case s1 = 24
        case s2 = 19
        case s3 = 17
        case s4 = 15
        case s5 = 13
        case s6 = 11
        case s7 = 9
        case s8 = 8
    }

    // MARK: - 标题（medium）

    static var h2: UIFont { font(.s2, .medium) }
    static var h3: UIFont { font(.s3, .medium) }
    static var h4: UIFont { font(.s4, .medium) }
    static var h5: UIFont { font(.s5, .medium) }
    static var h6: UIFont { font(.s6, .medium) }
    static var h7: UIFont { font(.s7, .medium) }

    // MARK: - 正文（regular）

    static var p1: UIFont { font(.s1, .regular) }
    static var p2: UIFont { font(.s2, .regular) }
    static var p3: UIFont { font(.s3, .regular) }
    static var p4: UIFont { font(.s4, .regular) }
    static var p5: UIFont { font(.s5, .regular) }
    static var p6: UIFont { font(.s6, .regular) }
    static var p7: UIFont { font(.s7, .regular) }

    // MARK: - 粗正文（bold）

    static var boldP2: UIFont { font(.s2, .bold) }
    static var boldP3: UIFont { font(.s3, .bold) }
    static var boldP4: UIFont { font(.s4, .bold) }
    static var boldP5: UIFont { font(.s5, .bold) }
    static var boldP6: UIFont { font(.s6, .bold) }
    static var boldP7: UIFont { font(.s7, .bold) }
    static var boldP8: UIFont { font(.s8, .bold) }

    // MARK: - 细正文（light）

    static var lightP2: UIFont { font(.s2, .light) }
    static var lightP3: UIFont { font(.s3, .light) }
    static var lightP4: UIFont { font(.s4, .light) }
    static var lightP5: UIFont { font(.s5, .light) }
    static var lightP6: UIFont { font(.s6, .light) }
    static var lightP7: UIFont { font(.s7, .light) }

    /// 二十四个出口共用这一个 —— 免得六个点数在四套字重里各写一遍。
    private static func font(_ step: Step, _ weight: UIFont.Weight) -> UIFont {
        UIFont.scaled(step.rawValue, weight: weight)
    }
}

// ⚠️ 出口全是计算属性（`var`），不能写成 `let`：
// 字号取决于**当前**的系统文字大小，缓存住就再也不会跟着变了。
