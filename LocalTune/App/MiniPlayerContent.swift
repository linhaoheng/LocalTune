import Foundation

/// 「谁在播」→ 迷你条那一行要显示的东西 —— **`PlayerState` 到 `MiniPlayerBar.Content` 的翻译**。
///
/// ## 为什么住在这儿（`App` 层、跟容器同一个文件夹）
///
/// 这条翻译两头都得认识：一头是 `PlayerState`（`Playback` 层），
/// 一头是 `MiniPlayerBar.Content` / `MiniPlayerBar.Progress`（跟着条子走的展示结构）。
///
/// 🔴 **它只有一个使用方** —— 底部容器 `MiniBarNavController`。按「一个还是多个」的判据
/// （只有一个功能用的，就躺在那个功能的文件夹里），它**不单开一层**、
/// 也不上 `Components`——
/// 它就跟容器住同一层、同一个文件夹。
///
/// 两边的硬线把它夹在中间：
///
/// - `MiniPlayerBar` **不认识播放器**（见它文件头那条硬线）⇒ 翻译不能塞进组件本体；
/// - 容器自己**不算内容**（算出一份可直接渲染的快照是 ViewModel 那类活儿）⇒
///   翻译也不落在 `MiniBarNavController` 里。
///
/// 于是它单独站一处：**纯映射、无状态**，谁都不碰、谁都能读。
///
/// ## 它不是 ViewModel
///
/// ⚠️ **无状态纯映射**：不订流、不存状态、不碰 UI。
/// 「订阅状态」那一步仍归宿主（那是页面 / 容器该做的三件事之一），这里只管"翻"。
/// 所以它是 `enum` 命名空间、不是带状态的类型（同 `AppArtwork` 的写法）。
enum MiniPlayerContent {

    /// 把「谁在播」＋两侧 peek 翻成条子内容。
    ///
    /// 🔴 **预览必须来自与 `playPrevious` / `playNext` 同一套 peek**
    /// （`PlayManager.peekPreviousTrack` / `peekNextTrack`）—— 另写一份 `adjacentTrack` 是错的。
    static func from(
        _ state: PlayerState,
        previous: Track?,
        next: Track?
    ) -> MiniPlayerBar.Content {
        let previousNeighbor = queueNeighbor(peeked: previous)
        let nextNeighbor = queueNeighbor(peeked: next)

        guard let track = state.track else {
            return MiniPlayerBar.Content(
                title: MiniPlayerBar.Content.notPlayingTitle,
                isPlaybackActive: false,
                artworkPath: nil,
                previousPreview: preview(from: previousNeighbor),
                nextPreview: preview(from: nextNeighbor)
            )
        }
        return MiniPlayerBar.Content(
            title: track.title,
            isPlaybackActive: state.isPlaybackActive,
            artworkPath: track.artworkPath,
            previousPreview: preview(from: previousNeighbor),
            nextPreview: preview(from: nextNeighbor)
        )
    }

    /// 顶上那条进度 —— **不进 `Content`**。10Hz 推 Content 会掐 Marquee。
    ///
    /// 引擎还没为当前曲装过（冷恢复）→ 不画。没当前曲或总长 0 → 不画。
    /// 装过之后有歌就画，进度为 0 也画（空轨）。
    static func progress(
        from state: PlayerState,
        elapsed: TimeInterval
    ) -> MiniPlayerBar.Progress {
        guard let track = state.track else { return .hidden }
        guard !state.engineNeedsPrepare else { return .hidden }
        let duration = resolvedPlaybackDuration(
            engine: state.duration,
            library: track.durationMs
        )
        guard duration > 0 else { return .hidden }
        let ratio = elapsed.isFinite ? elapsed / duration : 0
        return MiniPlayerBar.Progress(
            fraction: Float(min(max(ratio, 0), 1)),
            visible: true
        )
    }

    private static func preview(from neighbor: QueueNeighbor) -> MiniPlayerBar.Content.Preview? {
        switch neighbor {
        case .available(let track):
            return MiniPlayerBar.Content.Preview(
                title: track.title,
                artworkPath: track.artworkPath
            )
        case .unavailable:
            return nil
        }
    }
}
