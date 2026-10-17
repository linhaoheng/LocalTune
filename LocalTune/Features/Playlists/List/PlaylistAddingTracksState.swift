import Foundation

/// 歌曲页多选进入的「添加到播放列表」模式：这一趟模态添加的输入歌曲和已处理歌单。
///
/// 页面通用状态不认识它 —— 从歌曲页多选进来才存在（见 `PlaylistsViewController` 的构造参数）。
final class PlaylistAddingTracksState {
    let trackIDs: [Track.ID]
    var addedPlaylistIDs: Set<Playlist.ID> = []

    init(trackIDs: [Track.ID]) {
        self.trackIDs = trackIDs
    }
}
