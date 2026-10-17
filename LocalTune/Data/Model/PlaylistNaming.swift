import Foundation

/// 歌单名能不能保存 —— **全 App 只有这一处**（列表页 / 详情页共用）。
///
/// 空名字（去空白之后）不许写库：建单有默认名兜底，改名没有。
enum PlaylistNaming {

    /// 这个名字能不能用来改名 / 保存。
    static func canSave(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 去空白后的名字；空串调用方不该拿去写库（先过 `canSave`）。
    static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
