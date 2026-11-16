import Foundation

/// 播放速度 —— **一个整数百分数**（`hundredths`，`100` ＝ 1×），不是浮点。
///
/// ## 为什么不用 `Float`
///
/// 速度要在列表里跟五档预置比「是不是同一档」（打勾），还要在「自定义」那行显示当前值。
/// 浮点比出来的是"位模式一样不一样"：`Float(1.35)` 和算出来的 1.35 差一个 ULP 就不相等，
/// 勾会莫名其妙不亮、括号里的数字也会跳。整数百分数从输入 → 存盘 → 比对全程精确。
///
/// 范围 **0.1×–4×**（`10...400`）；越界的一律夹回来。
///
/// ⚠️ **五档预置只是这个类型的五个常量**，不是它的全部取值 —— 用户可以敲 `1.35`。
///
/// ⚠️ 屏幕上显示的数字**不带 `×`**（`0.75` / `1` / `1.35`）—— 这一页的标题就是「速度」，
/// 每行再缀一个 `×` 只是噪音。见 `display`。
struct PlaybackRate: Equatable, Codable {

    /// 1× 的一百分之一：`75` ＝ 0.75×、`135` ＝ 1.35×。
    let hundredths: Int

    /// 夹到合法范围里 —— 越界的不报错，直接贴边（保证"拿到手的一定是能播的"）。
    init(hundredths: Int) {
        self.hundredths = min(Self.maxHundredths, max(Self.minHundredths, hundredths))
    }

    // MARK: - 五档预置

    static let x075 = PlaybackRate(hundredths: 75)
    static let x1 = PlaybackRate(hundredths: 100)
    static let x125 = PlaybackRate(hundredths: 125)
    static let x15 = PlaybackRate(hundredths: 150)
    static let x2 = PlaybackRate(hundredths: 200)

    /// 速度页列出来打勾的那五档 —— **顺序就是屏幕上的顺序**。
    static let presets: [PlaybackRate] = [.x075, .x1, .x125, .x15, .x2]

    static let minHundredths = 10
    static let maxHundredths = 400

    /// 是不是那五档之一 —— 不是的话，速度页上「自定义速度」那行打勾。
    var isPreset: Bool { Self.presets.contains(self) }

    // MARK: - 字面

    /// 屏幕上显示的那个数 —— `0.75` / `1` / `1.25` / `1.35` / `4`，**不带 `×`**，尾零去掉。
    ///
    /// 列表五档和「自定义速度（1.35）」括号里都用它，输入弹窗的预填也用它 ——
    /// 一处算、三处显示，免得列表写 `1.5`、括号里写 `1.50`。
    var display: String {
        let whole = hundredths / 100
        let fraction = hundredths % 100
        guard fraction != 0 else { return "\(whole)" }
        guard fraction % 10 == 0 else {
            return "\(whole).\(fraction < 10 ? "0\(fraction)" : "\(fraction)")"
        }
        return "\(whole).\(fraction / 10)"
    }

    // MARK: - 输入

    /// 把弹窗里敲的字变成速度；**不合法给 `nil`**（确认键亮不亮就看它）。
    ///
    /// 接受 `1.35` / `1,35`（小数点跟着键盘语言变）/ `1` / `1.3` / `.5`；
    /// 最多两位小数；**越出 0.1–4 算不合法** —— 不悄悄夹，
    /// 夹了用户会以为自己输对了。
    static func parse(_ text: String) -> PlaybackRate? {
        let normalized = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, let value = Double(normalized) else { return nil }

        // 最多两位小数：`1.357` 不合法（不是四舍五入成 1.36 就完事）。
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.count == 1 || parts[1].count <= 2 else { return nil }

        let scaled = (value * 100).rounded()
        guard scaled >= Double(minHundredths), scaled <= Double(maxHundredths) else { return nil }
        return PlaybackRate(hundredths: Int(scaled))
    }

    // MARK: - 存档

    /// 旧存档存的是枚举的 `rawValue`（`"x075"` / `"x1"` / …），新存档存整数。
    ///
    /// 🔴 **两种都得能解**：解不开的是**整份** `EffectsArchive`（EQ 曲线、用户预设全在里面，
    /// 见 `AppSettings.effectsArchive`）—— 不能因为速度这一格换了写法，把人家调好的 EQ 一起丢掉。
    private static let legacyHundredths: [String: Int] = [
        "x075": 75,
        "x1": 100,
        "x125": 125,
        "x15": 150,
        "x2": 200
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let hundredths = try? container.decode(Int.self) {
            self.init(hundredths: hundredths)
            return
        }
        let raw = try container.decode(String.self)
        self.init(hundredths: Self.legacyHundredths[raw] ?? 100)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hundredths)
    }
}
