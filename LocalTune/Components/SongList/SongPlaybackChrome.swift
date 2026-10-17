import Foundation

/// 列表行「谁在播」的呈现输入 —— 页面从 `PlayerState` 投影过来，行只画、不订播放器。
struct SongPlaybackChrome: Equatable {
    /// 当前装的那一首；没有 = 还没点过歌。
    var currentTrackID: Track.ID?
    /// 是不是真的在出声（对应 `PlayerState.isActuallyPlaying`）——
    /// 竖杠动画用它；暂停时当前行仍蓝字 + 静竖杠。
    var isActuallyPlaying: Bool
    /// 播放会话是否活跃（对应 `PlayerState.isPlaybackActive`，**在装也算在播**）——
    /// **播放键图态**用它（封面流那颗键）：用户刚点了这一首，换歌那几百毫秒里
    /// 要看到"在播"；画成"没在播"会先闪一下播放键、再跳回来。
    /// ⚠️ 和上面的 `isActuallyPlaying` 答的是两个问题，别互相替代（同 `PlayerState` 那条规矩）。
    var isPlaybackActive: Bool

    static let idle = SongPlaybackChrome(
        currentTrackID: nil,
        isActuallyPlaying: false,
        isPlaybackActive: false
    )

    /// 从播放真相投影 —— **全工程只这一处**拼字段，曲库 / 歌单详情 VM 都调它。
    /// 一次投影出两个布尔：同一个 `PlayerState`、同一行取，天然一致。
    static func from(_ state: PlayerState) -> SongPlaybackChrome {
        SongPlaybackChrome(
            currentTrackID: state.track?.id,
            isActuallyPlaying: state.isActuallyPlaying,
            isPlaybackActive: state.isPlaybackActive
        )
    }

    func isCurrent(_ id: Track.ID) -> Bool { currentTrackID == id }

    /// 点这一行该干什么 —— **正在播这首 → 开播放页，否则开播**。
    ///
    /// 判据在 chrome 上，不散进两个 ViewModel。
    func rowTapOutcome(for id: Track.ID) -> SongRowTapOutcome {
        if isCurrent(id), isActuallyPlaying { return .presentNowPlaying }
        return .startPlayback
    }
}

/// 点歌曲列表一行之后的去向 —— 用 enum，不用 `Bool`。
enum SongRowTapOutcome {
    /// 这首正在出声 → 打开播放页。
    case presentNowPlaying
    /// 其它 → 开播 / 切歌。
    case startPlayback
    /// 🔴 **文件不在本机** → 不播，给一句提示。
    ///
    /// ⚠️ 它**不是**「播放失败」：播放失败是"文件在、但解不开"，两者的出路完全不同
    ///（一个要重新导入，一个要换一份文件）。判据在各自 ViewModel 的 `handleRowTap` 最前面。
    case missingFile
}
