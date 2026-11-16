import Foundation

/// **队列本体** —— 现在排着哪些歌、播到第几格、插了谁的队。
///
/// 🔴 **它是个纯容器**：不认识引擎、不认识界面、不认识 `PlayerState`。
/// 外面给它一串**编号**，它只回答"往后走是哪一首""往前退是哪一首"。
/// ⇒ 整个类没有一处副作用，**能直接单测**。
///
/// ## 🔴 它只存编号，不存歌本身
///
/// `Track` 是**值类型** ⇒ 存进来就是一份**拷贝**。歌被编辑过（歌词 / 歌名 / 封面……）之后，
/// 那份拷贝**悄悄过期**，而且不会报错 —— 只会"切回来的时候还是旧的"。
///
/// 「歌是什么」只有一处：`PlayManager` 手里那张 `[Track.ID: Track]` 表。
/// 队列只记"第几格是哪一首的编号"，要用的时候去表里查。
/// ⇒ 这样**没有"内容变了要通知队列"这回事**，也就漏不了。
///
/// ## 三份顺序，各管各的
///
/// - `trackIDs` —— **现在**的播放顺序（洗牌改的是它）；
/// - `originalIDs` —— 用户**给进来**的那个顺序，关掉洗牌时按它恢复；
/// - `upNextIDs` —— 「下一首播放」点进来、**还没轮到**的那些（有序：先点的在前）。
///
/// ⚠️ 少了 `originalIDs` 就没法"关掉洗牌变回原样"；少了 `upNextIDs` 就没法"连点两次下一首播放
/// 仍然是先点的先播"（只看 `trackIDs` 的话，第二次会插到第一次前面去）。
///
/// ## 线程
///
/// **只在主线程用**（`PlayManager` 持有它，`PlayManager` 的所有动作和引擎事件都在主线程）。
/// 它不是线程安全的类型，也不打算是 —— 不需要锁，因为没有第二个线程碰它。
@MainActor
final class PlayQueue {

    /// 现在的播放顺序。
    private(set) var trackIDs: [Track.ID] = []

    /// 现在播的是第几格。
    ///
    /// ⚠️ **可以是 `-1`** —— 那表示"当前那首已经不在队列里了"：它从库里被删掉、或被移出了队列
    /// （见 `applyRemoval`）。这时 `advance` 从队首重新开始，`currentID` 返回 `nil`。
    private(set) var currentIndex = 0

    /// 用户给进来的原始顺序 —— 关掉洗牌时按它恢复。
    private var originalIDs: [Track.ID] = []

    /// 「下一首播放」点进来的、还没轮到的那些。
    private var upNextIDs: [Track.ID] = []

    /// 洗牌开关 —— **实现细节**，由 `PlayManager.setPlaybackMode(.shuffle)` 驱动；
    /// 不进 `PlayerState`（用户只认互斥的 `PlaybackMode`）。
    private var isShuffled = false

    // MARK: - 读

    /// 现在这一格是哪一首（**编号**）；队列空的时候是 `nil`。
    var currentID: Track.ID? {
        trackIDs.indices.contains(currentIndex) ? trackIDs[currentIndex] : nil
    }

    var isEmpty: Bool { trackIDs.isEmpty }

    /// 存档用：三份顺序的编号 ＋ 游标，收成一个**具名值**（`PlaybackQueueCapture`）。
    ///
    /// ⚠️ **只取不需要判断的那几样**：给出去之后由 `Decisions/PlaybackSessionPolicy` 的
    /// 纯函数拼成快照 —— 这一层不产出、也不认识 `PlaybackSessionSnapshot`。
    var sessionCapture: PlaybackQueueCapture {
        PlaybackQueueCapture(
            trackIDs: trackIDs,
            originalIDs: originalIDs,
            upNextIDs: upNextIDs,
            currentIndex: currentIndex
        )
    }

    /// 存档恢复：原样灌回，**不**重新洗牌。
    func restore(
        trackIDs: [Track.ID],
        originalIDs: [Track.ID],
        upNextIDs: [Track.ID],
        currentIndex: Int,
        isShuffled: Bool
    ) {
        self.trackIDs = trackIDs
        self.originalIDs = originalIDs
        self.upNextIDs = upNextIDs
        self.isShuffled = isShuffled
        if trackIDs.indices.contains(currentIndex) {
            self.currentIndex = currentIndex
        } else {
            self.currentIndex = 0
        }
    }

    /// 插队区在 `trackIDs` 里占的那几格：紧跟在当前格后面。
    ///
    /// ⚠️ 游标 `-1` 时它从队首开始 —— 和 `insertNext` 插进去的位置是同一条算式。
    private var pendingRange: Range<Int> {
        (currentIndex + 1)..<(currentIndex + 1 + upNextIDs.count)
    }

    // MARK: - 换队列

    /// 换一整队歌，从第 `index` 首开始播。
    ///
    /// 🔴 `originalIDs` 和 `trackIDs` **一起换** —— 只换一半的话，用户拖过排序之后再开洗牌，
    /// 队列会按**换之前的**顺序重建，那次排序等于白做。
    ///
    /// ⚠️ 开着洗牌时，点的那首**排到队首**、其余打乱：用户点的是"我要听这一首"，
    /// 不能因为开着随机就把这首也打散到队列中间去。
    func replace(with ids: [Track.ID], startingAt index: Int) {
        originalIDs = ids
        upNextIDs = []

        guard ids.indices.contains(index) else {
            trackIDs = ids
            currentIndex = 0
            return
        }

        if isShuffled {
            let picked = ids[index]
            trackIDs = [picked] + ids.filter { $0 != picked }.shuffled()
            currentIndex = 0
        } else {
            trackIDs = ids
            currentIndex = index
        }
    }

    /// 清空 —— 队列到头、或者歌全被删光时用。
    func clear() {
        trackIDs = []
        originalIDs = []
        upNextIDs = []
        currentIndex = 0
    }

    // MARK: - 插队

    /// 「下一首播放」。
    ///
    /// 🔴 **尾插**：先点的先播。头插的话，先点 A 再点 B 会变成"B、A" ——
    /// 用户的心理预期是他点的顺序，不是倒过来的那个。
    ///
    /// ⚠️ 插进 `trackIDs` 的位置是「**已有的插队项之后**」：连点两次下一首播放，
    /// 第二次要排在第一次后面，而不是插到它前面去。
    ///
    /// 🔴 **同一首歌不在队列里出现两份**（`insertNext` 先摘掉再插）：
    /// 歌已经排在队列别处 ⇒ **挪过来**，不复制。
    /// 唯一例外是**正在播的那首** —— 那是「这首再听一遍」，后面再插一份。
    /// ⚠️ 挪动只动播放顺序、不动 `originalIDs`：关洗牌时它照样按插队项排在当前曲后面（见 `merging`）。
    func insertNext(_ id: Track.ID) {
        if id != currentID, let existing = trackIDs.firstIndex(of: id) {
            detach(at: existing)
        }
        upNextIDs.append(id)
        let insertAt = min(currentIndex + upNextIDs.count, trackIDs.count)
        trackIDs.insert(id, at: insertAt)
    }

    // MARK: - 洗牌

    /// 开 / 关洗牌。当前曲不换；关时恢复 `originalIDs` 并把游标落回该曲原位。
    func setShuffled(_ on: Bool) {
        guard on != isShuffled else { return }
        isShuffled = on
        guard let current = currentID else { return }

        let pendingIDs = Set(upNextIDs)
        if on {
            let rest = originalIDs.filter { $0 != current && !pendingIDs.contains($0) }
            trackIDs = [current] + upNextIDs + rest.shuffled()
            currentIndex = 0
            return
        }

        let restored = Self.order(
            afterDisablingShuffle: current,
            original: originalIDs,
            pending: upNextIDs
        )
        trackIDs = restored.trackIDs
        currentIndex = restored.currentIndex
    }

    // MARK: - 走

    /// 看一眼下一首是谁（**编号**）—— **不动队列**（游标、插队区都不变）。
    ///
    /// ⚠️ 有它的理由：决定"要不要往下跳"的时候**不能先跳了再看** ——
    /// 跳完才发现该放弃的话，游标已经白白往前走了一格（见 `PlayManager.handleFailure`）。
    func peekNext(mode: PlaybackMode) -> Track.ID? {
        // 游标 -1 ＝ 当前那首不在队列里了，它之后的第一格就是队首（同 `advance`）。
        if currentIndex < 0 { return trackIDs.first }
        if !upNextIDs.isEmpty { return upNextIDs.first }

        guard let index = PlayNext.nextIndex(current: currentIndex, count: trackIDs.count, mode: mode) else {
            return nil
        }
        return trackIDs[index]
    }

    /// 看一眼上一首是谁（**编号**）—— **不动队列**（同 `peekNext`）。
    ///
    /// 🔴 迷你条滑动预览必须走它，不能另写一套「相邻下标」——
    /// 预览跟真正的 `previous` 不是同一规则就会出现「封面是 A、耳朵是 B」。
    func peekPrevious(mode: PlaybackMode) -> Track.ID? {
        guard let index = PlayNext.previousIndex(
            current: currentIndex,
            count: trackIDs.count,
            mode: mode
        ) else {
            return nil
        }
        return trackIDs[index]
    }

    /// 往后走一首（返回**编号**）。`nil` ＝ **到头了**（顺序播放走到最后一首）——
    /// 调用方收到 `nil` 就该停下，别再叫它。
    func advance(mode: PlaybackMode) -> Track.ID? {
        // 游标 -1 ＝ 当前那首**已经不在队列里**了（它从库里被删掉、或被移出了队列）。
        // 它之后的第一格就是队首 —— 游标 -1 时插队区也从队首开始（见 `insertNext`），
        // 所以这一格是什么、要不要从插队区里划掉，两种情况合在一起处理。
        if currentIndex < 0 {
            guard !trackIDs.isEmpty else { return nil }
            currentIndex = 0
            if !upNextIDs.isEmpty { upNextIDs.removeFirst() }
            return currentID
        }

        // 插队优先：用户明确说了"下一首播这个"，模式管不着它。
        // 插队项就排在当前项后面那一格（`insertNext` 插进去的位置）。
        if !upNextIDs.isEmpty {
            upNextIDs.removeFirst()
            currentIndex += 1
            return currentID
        }

        guard let index = PlayNext.nextIndex(current: currentIndex, count: trackIDs.count, mode: mode) else {
            return nil
        }

        // 🔴 打乱队列回绕到队首**不重洗**，按这一轮的顺序从头再来：
        // 重洗的话"下一首"要到走的那一刻才存在，`peekNext` 看到的跟真走到的就不是同一首
        // （迷你条预览 A、耳朵里是 B；无缝排的下一首也会被判成孤儿）。
        // 刚播完那首在队尾，回绕到队首不会马上重放它。
        currentIndex = index
        return currentID
    }

    /// 直接跳到第 `index` 格（队列页点了一行），返回**编号**。越界 ⇒ `nil`，什么都不动。
    ///
    /// 🔴 **插队区先并进 `originalIDs` 再跳**：插队项是"跟在**原来那首**后面"的，游标一跳走，
    /// 这层关系就不成立了 —— 不并进去的话，关洗牌时那些还没播的插队项会从队列里消失
    /// （`originalIDs` 里本来就没有它们）。播放顺序本身一格不动。
    func jump(to index: Int) -> Track.ID? {
        guard trackIDs.indices.contains(index) else { return nil }
        settlePending()
        currentIndex = index
        return currentID
    }

    /// 往前退一首（返回**编号**）。`nil` ＝ 到头了（顺序播放已经停在第一首）。
    ///
    /// ⚠️ 插队项**不参与**"上一首"：它们是"接下来要播的"，往回退走的是队列本身的顺序。
    func previous(mode: PlaybackMode) -> Track.ID? {
        guard let index = PlayNext.previousIndex(current: currentIndex, count: trackIDs.count, mode: mode) else {
            return nil
        }
        currentIndex = index
        return currentID
    }

    // MARK: - 歌被删了

    /// 库里这些歌没了 —— 把队列里的它们剔掉。
    ///
    /// ⚠️ 这个函数**只管队列、不碰引擎**：剔哪些歌、游标怎么修都在这儿；
    /// "正在播的那首被剔了 → 下一首还是停"是调用方（`PlayManager.removeTracks`）的事。
    ///
    /// ⚠️ **三份顺序一起剔**：只剔 `trackIDs` 的话，关掉洗牌时被删的歌会从 `originalIDs` 里
    /// 原样冒回来 —— 那时候它已经不在库里了，播出去就是"文件找不到"。
    func applyRemoval(_ removed: Set<Track.ID>) {
        guard !removed.isEmpty, !trackIDs.isEmpty else { return }

        let nextCursor = Self.cursor(afterRemoving: removed, from: trackIDs, at: currentIndex)

        trackIDs.removeAll { removed.contains($0) }
        originalIDs.removeAll { removed.contains($0) }
        upNextIDs.removeAll { removed.contains($0) }

        guard !trackIDs.isEmpty else {
            clear()
            return
        }
        currentIndex = nextCursor
    }

    /// 队列页 × 掉**第 `index` 格**（只是移出队列，歌还在库里）。
    ///
    /// 🔴 **按位置、不按歌曲 id**：正在播的那首点过「下一首播放」时，队列里会有它的两份
    /// （见 `insertNext`），按 id 删就会一次删掉两行。
    /// 游标规则同 `applyRemoval`：删的是当前格 ⇒ 停在前一格，下一次 `advance` 落在它原来的下一首。
    ///
    /// ⚠️ `originalIDs` 只在**这首歌已经不在播放顺序里**时才跟着删 —— 还剩一份（"再听一遍"那份）
    /// 就留着，关洗牌时才找得到它的位置。
    func remove(at index: Int) {
        guard trackIDs.indices.contains(index) else { return }
        let removed = detach(at: index)
        if !trackIDs.contains(removed) {
            originalIDs.removeAll { $0 == removed }
        }
        if trackIDs.isEmpty { clear() }
    }

    /// 剔掉这些歌之后，游标该落在第几格 —— **纯函数**：只吃值，跟队列对象没关系，能单独测。
    ///
    /// 🔴 **为什么单独拎成一个能调的函数**：索引修错了**不会报错**，只会"跳过一首歌"、
    /// 或者"同一首播两遍"—— 那种错只能靠单测抓（硬线第 3 条：队列推进必须能单测）。
    ///
    /// 两条规则：
    /// 1. 当前那首**之前**剔掉几格，游标就往回挪几格；
    /// 2. **当前那首自己也被剔了** **再往回挪一格** ——
    ///    挪到它原来那一格的前面，下一次 `advance` 才正好落在**它原来的下一首**上。
    ///
    /// ⚠️ 挪成 `-1` 是合法的，见 `currentIndex` 的说明。
    static func cursor(
        afterRemoving removed: Set<Track.ID>,
        from trackIDs: [Track.ID],
        at currentIndex: Int
    ) -> Int {
        let head = Array(trackIDs.prefix(max(currentIndex, 0)))
        let survivingBefore = head.filter { !removed.contains($0) }.count
        let currentSurvived = trackIDs.indices.contains(currentIndex)
            && !removed.contains(trackIDs[currentIndex])
        return currentSurvived ? survivingBefore : survivingBefore - 1
    }

    /// 删掉第 `index` 格之后，游标该落在第几格 —— 规则同 `cursor(afterRemoving:from:at:)`：
    /// 删在当前格之前或正好是当前格 ⇒ 往回挪一格。
    static func cursor(afterRemovingAt index: Int, at currentIndex: Int) -> Int {
        index <= currentIndex ? currentIndex - 1 : currentIndex
    }

    /// 关洗牌：恢复原序，游标落在当前曲；插队项仍紧跟其后。
    static func order(
        afterDisablingShuffle current: Track.ID,
        original: [Track.ID],
        pending: [Track.ID]
    ) -> (trackIDs: [Track.ID], currentIndex: Int) {
        let trackIDs = merging(pending: pending, into: original, after: current)
        guard let idx = trackIDs.firstIndex(of: current) else {
            return ([current] + trackIDs, 0)
        }
        return (trackIDs, idx)
    }

    /// 把插队项排进一份顺序里：**紧跟在 `anchorID` 那首后面**；找不到它（或没有）就排在最前。
    ///
    /// 🔴 插队项从原位置**挪走**（`insertNext` 挪过来的那些）—— 但 `anchorID` 自己**不挪**：
    /// 正在播的那首点过「下一首播放」时，插队区里有它的一份，它在原序里那一格仍是锚点。
    /// 少了这条例外，锚点会被当成插队项滤掉，当前曲就找不到原位了。
    static func merging(
        pending: [Track.ID],
        into order: [Track.ID],
        after anchorID: Track.ID?
    ) -> [Track.ID] {
        let pendingIDs = Set(pending)
        var merged = order.filter { !pendingIDs.contains($0) || $0 == anchorID }
        let insertAt = anchorID
            .flatMap { id in merged.firstIndex { $0 == id } }
            .map { $0 + 1 } ?? 0
        merged.insert(contentsOf: pending, at: insertAt)
        return merged
    }

    // MARK: - 私有

    /// 从播放顺序里摘掉第 `index` 格，游标和插队区跟着修 —— **不碰 `originalIDs`**
    /// （"挪位"和"移出队列"都走这儿，`originalIDs` 要不要跟着删由调用方定）。
    @discardableResult
    private func detach(at index: Int) -> Track.ID {
        if pendingRange.contains(index) {
            upNextIDs.remove(at: index - pendingRange.lowerBound)
        }
        currentIndex = Self.cursor(afterRemovingAt: index, at: currentIndex)
        return trackIDs.remove(at: index)
    }

    /// 插队区并进 `originalIDs`（排在当前曲后面），插队标记清空 —— 播放顺序不动。
    private func settlePending() {
        guard !upNextIDs.isEmpty else { return }
        originalIDs = Self.merging(pending: upNextIDs, into: originalIDs, after: currentID)
        upNextIDs = []
    }
}
