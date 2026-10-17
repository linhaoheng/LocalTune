import Foundation

extension ImportProgress {

    /// 进度浮层的主行：「已导入 N 首」。
    ///
    /// ⚠️ 跑的过程中报的是当前进度里那个数、跑完报的是结果里的总数，中间**不能让说法变一次** ——
    /// 所以这句话只有一处出处（下面那个 static），`ImportResult.hudMessage` 也调它。
    var hudMessage: String { Self.hudMessage(imported: imported) }

    /// "已导入 N 首"这句话的唯一出处。
    static func hudMessage(imported: Int) -> String { "已导入 \(imported) 首" }
}
