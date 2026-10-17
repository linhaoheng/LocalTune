import Foundation

/// 「逐字扫光」怎么算 —— **纯函数**，零 UIKit，能拷出去当命令行跑（4a 那套老办法）。
///
/// ## 四组函数（按一次渲染的调用顺序）
///
/// 1. `segments(of:)` —— 一行逐字切成「第几个字 ~ 第几个字」的段；
/// 2. `effectiveDuration(for:)` —— 这个词**扫多久**；
/// 3. `sweepProgress(for:at:)` —— 这个词**现在扫到几成**；
/// 4. `runState(isCurrentLine:hasKaraoke:isPlaybackActive:isOnScreen:)` —— **这一帧该不该画**。
///
/// ## 🔴 时长就是数据本身 —— 不封顶，也不垫底
///
/// 一个词扫多久 = 它真唱多久（`end − start`）。这个 `end` 是解析层给的：
/// 中间词 = 下一个词的起点，末字 = 正文里那个结束标记（`LyricsParser`）。
///
/// 实测（`347230` / `186016` 两份真档）：**每个字的「长」都等于它到下一字的间隔**
///（432/432、315/315）⇒ 行内的间隔**就是**这个字唱的时间，不是间奏 ⇒ 照原值扫。
/// 行与行之间的间奏归**行级**管，跟这里无关。
///
/// 🔴 **下限 `0.18` 已撤掉** —— 跟封顶（`min(0.90, 0.42 + …)`）是同一个错：
/// 拿一个常量顶掉实测出来的时长 ⇒ 扫光就不跟时长了。方向相反而已：封顶把**长音**扫快了，
/// 下限把**短字**扫慢了。
///
/// 86 首真档 / 37592 个字实测：自然时长 **< 0.18s 的占 15.8%**，全被垫到 0.18
/// ⇒ 扫得比唱得慢，而且伸进下一个字。而它本来要救的**零长字只占 0.053%**
///（86 首里 5 首有）—— 拿 15.8% 的失真换 0.05% 的可见，不划算。
/// 零长（`end == start`）改由 `sweepProgress` **明确定义**：开口那一刻就是满亮。
///
/// ## 出处
///
/// 骨架照 **primuse**（`LyricSyllablePlaybackTimingPolicy` ＋ `KaraokeLyricsPolicy`），
/// ⚠️ **不照**另一份 K 歌渲染器实现。
enum KaraokeSweepPolicy {

    // MARK: - 参数

    /// 算法参数 —— 跟 `CoverPalette.Tuning` 一个道理：留在**自己这儿**，**不进 `AppMetrics`**
    ///（那层只放"屏幕上看得见的尺寸"）。
    enum Tuning {

        /// 锚点最多能「老」多久 —— 超过就是**时间流断了**，停在原地等下一条。
        ///
        /// ⚠️ 这个数**不是从哪份资料抄的**：时间源是 10 Hz（每 100 ms 一条），
        /// 取 3 个多周期当"断了"的阈值。量级由时间源推得，真机若不顺再调。
        static let maximumAnchorAge: TimeInterval = 0.35

        /// 一帧最多往前推多少秒 —— 防 `CADisplayLink` 在卡顿后一次跳太远。
        /// ⚠️ 出处同上（量级由 10 Hz 推得），非一手证据。
        static let maximumFrameAdvance: TimeInterval = 0.22
    }

    // MARK: - 1. 切段

    /// 一行里的一个词 —— **它在整行文本里占哪几个字** ＋ 它什么时候唱。
    ///
    /// ⚠️ `range` 是 `NSString` 的字符区间（UTF-16），**不是** `String.Index` ——
    /// TextKit 收的就是这个（`KaraokeMaskRenderer`）。
    struct Segment: Equatable {

        /// 在整行文本里的位置。
        let range: NSRange

        let start: TimeInterval
        let end: TimeInterval
    }

    /// 一行 → 逐字段。**没有逐字就是空数组**（行级歌词、纯文本都走这条）。
    ///
    /// 🔴 这些段的 `range` **首尾相接、正好铺满整行** ——
    /// 因为 `LyricsLine.text` 在解析层就是 `syllables.map(\.text).joined()`（`LyricsParser.swift:195`）。
    static func segments(of line: LyricsLine) -> [Segment] {
        guard let syllables = line.syllables, !syllables.isEmpty else { return [] }
        var location = 0
        var segments: [Segment] = []
        segments.reserveCapacity(syllables.count)
        for syllable in syllables {
            let length = (syllable.text as NSString).length
            segments.append(
                Segment(
                    range: NSRange(location: location, length: length),
                    start: syllable.start,
                    end: syllable.end
                )
            )
            location += length
        }
        return segments
    }

    // MARK: - 2. 有效时长

    /// 这个词**实际扫多久**（秒）= 它真唱多久（`end − start`）。
    ///
    /// 🔴 **不封顶、也不垫下限** —— 源档给多少就是多少。唯一的一手是把"倒退"的
    ///（`end < start`，真档里 4/37592 个坏格）夹到 0；零长怎么画由 `sweepProgress` 定。
    static func effectiveDuration(for segment: Segment) -> TimeInterval {
        max(segment.end - segment.start, 0)
    }

    // MARK: - 3. 扫光进度

    /// 这个词**现在扫到几成**（`0…1`）。
    ///
    /// - 起点就是 `start`：字**开口那一刻**才起步（不提前预热）；
    /// - 终点：`start + effectiveDuration(for:)`；
    /// - 中间**线性**：`progress = (now − start) / duration` —— 和时间一一对应。
    ///
    /// ⚠️ **每个词各算各的**（不是整行一刀）：上一个词已经走完、这一个词还没开始的那一段，
    /// 这个函数给的就是 **0** —— 词与词之间的空隙于是**不亮**。
    ///
    /// 🔴 **零长（`duration <= 0`）的定义**：开口前是 0，**开口那一刻起就是 1**。
    /// 源档说这个字不占时间 ⇒ 它一露面就该是满亮，"扫"这个动作不存在。
    ///（这不是兜底 —— 是这种窗口本来就该这么读；顺手也堵住除零。）
    ///
    /// 🔴 **去掉 primuse 的 `easeOut`**：前快后慢会让字后半几乎不动，
    /// 观感像「扫完停一下再换下一字」。线性后接缝跟数据对齐。
    static func sweepProgress(for segment: Segment, at time: TimeInterval) -> Double {
        let duration = effectiveDuration(for: segment)
        guard duration > 0 else { return time >= segment.start ? 1 : 0 }
        let raw = (time - segment.start) / duration
        if raw <= 0 { return 0 }
        if raw >= 1 { return 1 }
        return raw
    }

    // MARK: - 4. 该不该跑

    /// 这一帧该不该让扫光动。
    enum RunState: Equatable {

        /// 每帧都画 —— 正在播、这一行有逐字、而且它就是当前行。
        case running

        /// **冻在最后一帧**（暂停）：还看得见扫到哪儿，但不往前跑。
        ///
        /// ⚠️ 跟 `idle` 分开是**必须**的：暂停时若直接不画，整行的逐字那一层会**整份消失**，
        /// 看着像"歌词被吞了一段"。
        case frozen

        /// 不画 —— 连那一层都不该露（不是当前行 / 没有逐字 / 不在屏上）。
        case idle
    }

    /// 三条状态 ＋ 一条"在不在屏上" → 该不该跑。
    ///
    /// 🔴 **返回 enum，不是 `Bool`** —— `running` 与 `frozen` 对界面是**两种做法**
    /// （起表 / 停表但保留这一帧），一个 `Bool` 表达不了。
    ///
    /// ⚠️ 这四条判据原来散在 cell 的三个地方（`didMoveToWindow` / `syncKaraokeTime` /
    /// `tick` 各写一遍）⇒ 收到这一处，**cell 只执行**。
    ///
    /// - Parameter isOnScreen: 列表自己给 —— 没有窗口 / 被藏起来都算不在屏上。
    static func runState(
        isCurrentLine: Bool, hasKaraoke: Bool, isPlaybackActive: Bool, isOnScreen: Bool
    ) -> RunState {
        guard isOnScreen, isCurrentLine, hasKaraoke else { return .idle }
        return isPlaybackActive ? .running : .frozen
    }
}
