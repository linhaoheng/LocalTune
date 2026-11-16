import Foundation

/// 换行时**每行各晚多久动** —— 「交错滚动」的时间账，纯函数。
///
/// 一条换行里所有可见行同时开始、同时结束，看着就是整块平移。要让它们错开，只能让每行
/// 有**自己的起步时刻**。
///
/// ## 结构：一个起点 ＋ 两个方向的延迟（每行走多久由调用点给）
///
/// ```
/// 每行：起步 = 这一趟的起点 ＋ delay(有符号档位)
/// 有符号档位 = 离起点行多远，正号＝运动方向
/// ```
///
/// 🔴 **不是「所有行同时结束」**。那是另一种做法：总时长钉死，靠压短靠后的行来错开 ——
/// 结果第一行走得像慢动作、最后一行窜过去，速度不一致。这里每行都走满**同一个**时长，
/// 只错开起点，所以「一道波推过去」的观感还在。
///
/// ## 两边步长不一样（2026-11-15）
///
/// 运动方向用 `forward`（22ms），反方向用更小的 `backward`（16ms）：
///
/// - 反方向那几行在**淡出遮罩**里，散太开像「上面也在正经交错」、抢戏；
/// - 但**不能是 0** —— 全是 0 的话，起点行上面那几行是同一刻起步、同一速度、同一时长的
///   一整块**硬板子**，和下面的扇形散开撞出一条硬边。
///
/// 所以反方向散得密一点：看得见是「被轻轻带起来的尾巴」，又不至于自己成为第二道波。
///
/// ## 整趟不封顶
///
/// 步长恒定、不按档数压缩（2026-11-15 撤掉封顶，统帅定）。整趟 = `最晚那行 ＋ 每行时长`，
/// 会随档数浮动（档数 8 ⇒ 0.48 秒、12 ⇒ 0.57 秒）。压步长会让同一首歌里「错开的疏密
/// 忽宽忽窄」，那比整趟长短不一更难看。
///
/// ⚠️ 反方向**不参与**整趟：正向永远更长（下方第 2 档就 22ms，上方第 2 档才 16ms）。
///
/// 出处：Salt Player 的 tween 求值是 `progress = (now - startsAt - delay) / duration`，
/// 而它的构造点里 `delay` 一律写 0、错峰全靠每行不同的 `startsAt` ⇒ 时长恒定、起点错开。
///
/// ## 三个函数
///
/// 1. `signedStep(of:from:scrollingDown:)` —— 这一行离起点行多远（带符号）；
/// 2. `delay(forStep:forward:backward:)` —— 这个档位晚多久起步；
/// 3. `remainingPlan(...)` —— 中途出生的那一格还剩多久。
///
/// 第 3 个**删过一次又加回来**：我一度以为「这一趟的格子是 `subviews` 快照、不存在中途加入」，
/// 删了它 —— 结果最后一句又开始「先站在终点、被上面的行压住」。真相是快照**不全**：
/// 换行跳到位以后最下面那行常常正卡在可见区边缘，`layoutIfNeeded()` 那一拍没造它。
///
/// ## 为什么单独一个文件
///
/// 这三条是「时序」自己的约束，跟 `UIViewPropertyAnimator`、跟列表、跟 cell 都没关系。
/// 放在视图里算，就只能靠肉眼验；放在这儿，一条测试就能钉住。
enum LyricCascadeTiming {

    /// 这一行离起点行**多远**，带符号：正号＝运动方向，负号＝反方向。
    ///
    /// 🔴 **以起点行为准、往运动方向数**：往下滚（`scrollingDown`）时起点行下面第 1 行是 `+1`、
    /// 上面第 1 行是 `−1`；往上滚整个反过来。
    ///
    /// 为什么以起点行为准、不以「运动方向前端」为准：前端先动的话，起点行在屏幕中间，
    /// 得等它上面几行先走完才轮到它，而用户眼睛正盯着起点行那一句。以它为 0，
    /// 波是**从视线所在处**往两边推出去的。
    ///
    /// - Parameters:
    ///   - index: 这一行的下标。
    ///   - origin: 起点行（0 档）的下标。
    ///   - scrollingDown: `delta > 0`（内容往上走、往歌词后面唱）。
    static func signedStep(of index: Int, from origin: Int, scrollingDown: Bool) -> Int {
        scrollingDown ? index - origin : origin - index
    }

    /// 这个档位晚多久起步（秒）。
    ///
    /// ```
    /// 正向（step ≥ 0）：max(step − 1, 0) × forward
    /// 反向（step < 0）：max(−step − 1, 0) × backward
    /// ```
    ///
    /// ## 🔴 第 0、±1 档同时起步
    ///
    /// `max(|档| − 1, 0)`：起点行和它**两边**紧邻的那一行都是 0 延迟 ——
    /// 起点行孤零零先动、邻行才跟上，中间会有一道「断裂」；三行一起起步就没有了。
    ///
    /// ## 🔴 反方向散得密（`backward` < `forward`）
    ///
    /// 反方向那几行在淡出遮罩里，散太开抢戏；但给 0 又会和起点行连成一整块硬板子。
    /// 取正向的**七成**左右：看得见「被轻轻带起来」，又不成为第二道波。
    ///
    /// ⚠️ **没有「最多散几档」这个参数**：反方向的行数天然有界
    /// （起点行上面就那么几行，起点行贴顶时是 0 行）。
    ///
    /// ⚠️ 正向**不封顶**：中途出生的格子可能落在这一趟最远那行之外，它只是更晚起步，
    /// 而它本来就在屏幕外 —— 以前靠「夹表长」处理，现在不需要了。
    ///
    /// - Parameters:
    ///   - step: 有符号档位（来自 `signedStep`）。
    ///   - forward: 运动方向相邻两档的间隔。
    ///   - backward: 反方向相邻两档的间隔。
    static func delay(
        forStep step: Int,
        forward: TimeInterval,
        backward: TimeInterval
    ) -> TimeInterval {
        let ahead = sanitize(forward)
        let behind = sanitize(backward)
        let spans = max(abs(step) - 1, 0)
        return Double(spans) * (step >= 0 ? ahead : behind)
    }

    /// 非有限值（`nan` / `inf`）落回 0，负值夹到 0 —— 绝不把 `inf` 喂给动画器。
    private static func sanitize(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? max(value, 0) : 0
    }

    /// 这一趟已经走了 `elapsed` 秒之后，**中途才出生的这一格**该等多久、走多久。
    ///
    /// ## 为什么需要它
    ///
    /// 每行的起步时刻是「**这一趟的起点** ＋ 延迟」，不是「**我出生的那一刻** ＋ 延迟」。
    /// 中途出生的格子（`startCascade` 的 `subviews` 快照之后才被造出来的那一格）
    /// 如果按后者算，它会比同序的行晚整整一个 `elapsed`。
    ///
    /// 🔴 **`subviews` 快照不全是有原因的**：换行跳到位以后，最下面那一行常常正卡在
    /// 可见区边缘，`layoutIfNeeded()` 那一拍还没造它，下一拍才造。所以「这一趟的参与者」
    /// 不等于快照，是**快照 ∪ 之后出生且属于这一趟的格子** —— 后者唯一的入口是
    /// `cellForItemAt`。
    ///
    /// ## 三种情况
    ///
    /// | `wait = 延迟 − 已过去` | 返回 | 含义 |
    /// |---|---|---|
    /// | `≥ 0` | `(wait, travel)` | 还没轮到它，照常等 |
    /// | `< 0` 但还没走完 | `(0, travel + wait)` | **已经在走了**，立刻起跑、走剩下的 |
    /// | 已经走完 | `nil` | 这一趟对它已经结束，站在终点 |
    ///
    /// 🔴 **中间那一档不能判成 `nil`。** 判成 `nil` 就是「直接站到终点」—— 别的行在拉、
    /// 它在跳（「第一句跳上去」和「最后一句先站在终点」是同一个错的两头）。
    /// 代价是它会从「跳之前的位置」起跑，比本该的位置**多退一小截**；
    /// 但 `elapsed` 是相邻两帧（约 16 毫秒），退回去的量 ≈ `delta × elapsed / travel` ≈ 2 点，看不见。
    ///
    /// ⚠️ **不反解缓动曲线**：那等于在纯函数里再实现一遍 `easeOut`，跟 Core Animation
    /// 各算一套曲线（两个真相）。这里只用「还剩多少时间」，曲线仍归 animator。
    ///
    /// - Parameters:
    ///   - elapsed: 这一趟从开始到现在过了多久。
    ///   - delay: 这一格原本排到的起步延迟（来自 `delay(forStep:forward:backward:)`）。
    ///   - travel: 每行自己的运动时长。
    /// - Returns: `(等多久, 走多久)`；`nil` ＝ 这一行这一趟已经走完，站在终点。
    static func remainingPlan(
        elapsed: TimeInterval,
        delay: TimeInterval,
        travel: TimeInterval
    ) -> (delay: TimeInterval, duration: TimeInterval)? {
        let travelTime = travel.isFinite ? max(travel, 0) : 0
        guard travelTime > 0 else { return nil }
        let passed = elapsed.isFinite ? max(elapsed, 0) : 0
        let wait = (delay.isFinite ? max(delay, 0) : 0) - passed
        // 已经开动的：`wait` 是负的，从 `travel` 里把这一截扣掉 —— 它只剩这么多时间了。
        let remaining = travelTime + min(wait, 0)
        guard remaining > 0 else { return nil }
        return (max(wait, 0), remaining)
    }
}
