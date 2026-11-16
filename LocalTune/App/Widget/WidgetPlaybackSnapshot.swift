import Foundation

/// 小组件跨进程通道上的**播放快照** —— 主 App 写、小组件扩展读。
///
/// 它是 IPC 载荷，不是「推给界面的状态」：
/// 字段只装原始数据（歌名 / 艺人 / 有无封面 / 播到几秒 / 带时间轴的歌词行），
/// 不存拼好的展示句 —— 「未在播放」这类文案由扩展的视图自己拼。
///
/// `Equatable` 是白拿的：发布者在落盘前用它去重，内容没变就不写、不 reload。
struct WidgetPlaybackSnapshot: Codable, Equatable {

    /// 歌名；空串 ＝ 没在播（视图据此画「未在播放」占位）。
    var title: String

    /// 艺人；空串不画。
    var artist: String

    /// 播放会话是否活跃（对应 `PlayerState.isPlaybackActive`，**装载中也算**）——
    /// 视图据此画播放/暂停键：换歌那几百毫秒里保持"在播"，按钮不闪。
    var isPlaying: Bool

    /// 封面文件还在吗 —— 视图据此决定画图还是占位音符。
    var hasArtwork: Bool

    /// 落盘时刻。**由 `WidgetSharedStore.save` 写入**，发布者构造时不填 ——
    /// 这样「内容没变」的去重才不会被时间戳打破。
    var updatedAt: TimeInterval

    /// 播到几秒（快照落盘那一刻的读数）。
    var elapsed: TimeInterval

    /// 当前这首歌带时间轴的歌词行（只有同步行）；没有歌词就是空数组。
    var lyrics: [WidgetLyricLine]

    /// 什么都没装的那一帧。
    static let empty = WidgetPlaybackSnapshot(
        title: "",
        artist: "",
        isPlaying: false,
        hasArtwork: false,
        updatedAt: 0,
        elapsed: 0,
        lyrics: []
    )
}

/// 快照里的一行歌词 —— 只留「几秒唱 + 唱什么」两样，逐字 / 译文不上小组件。
struct WidgetLyricLine: Codable, Equatable, Hashable {

    /// 行起点，秒。
    var time: TimeInterval

    /// 正文（已剥标签的纯文字）。
    var text: String
}

extension WidgetPlaybackSnapshot {

    /// 内容是否等价 —— **不看时间戳与播放头**。
    ///
    /// 这两样每次落盘都不同，带上它们去重等于没有去重（每次触发都会写盘
    /// 加一次 reload）。播放头的推进由扩展按 entry 时刻差还原。
    func hasSameContent(as other: Self) -> Bool {
        var lhs = self
        var rhs = other
        lhs.elapsed = 0
        lhs.updatedAt = 0
        rhs.elapsed = 0
        rhs.updatedAt = 0
        return lhs == rhs
    }

    /// 从通道上读旧数据用的宽容解码：**缺键给默认值**，不抛错。
    ///
    /// 通道两端会跟着版本走 —— 老版本写的快照缺后加的键时，退回默认值
    /// 比整份解码失败（于是显示空）体面；下一帧 save 会把数据补全。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
        isPlaying = try container.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        hasArtwork = try container.decodeIfPresent(Bool.self, forKey: .hasArtwork) ?? false
        updatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? 0
        elapsed = try container.decodeIfPresent(TimeInterval.self, forKey: .elapsed) ?? 0
        lyrics = try container.decodeIfPresent([WidgetLyricLine].self, forKey: .lyrics) ?? []
    }
}
