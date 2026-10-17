import Foundation

/// 10 段参量 EQ 的规格 —— 频点 / 带宽 / 行程是一套定好的值，不另发明。
///
/// 十条竖滑条的 ±12 与标签都在这儿。
enum EQSpec {

    static let bandCount = 10
    static let minGain: Float = -12
    static let maxGain: Float = 12
    static let bandwidth: Float = 1
    static let frequencies: [Float] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
}

/// 10 段增益 + 前级，单位 dB。合法范围 ±12；不够 10 段、越界，由 `clampedEQGains` 收。
///
/// 平线（10 段和前级都是 0）不是「关」这个独立态 —— 听感等于关，节点旁路。
struct EQGains: Equatable, Codable {

    var bands: [Float]
    var preamp: Float

    /// 新装默认：自定义 + 这条。听起来和关掉一样。
    static let flat = EQGains(bands: Array(repeating: 0, count: EQSpec.bandCount), preamp: 0)
}

/// 现在亮着哪张预设卡。没有独立的「关」。
///
/// `.none` = 一张都不亮（重置后）。听感仍看 `gains`；平线旁路，不等于「关」枚举。
enum EQSelection: Equatable, Codable {
    case none
    case builtIn(EQBuiltInPreset)
    case custom
    case user(id: String)
}

/// 9 个内置。声明顺序 = 卡片顺序，一个不动。
enum EQBuiltInPreset: String, CaseIterable, Codable {
    case plusEqual, harman, pop, rock, jazz, classical, vocal, bass, electronic

    /// 卡片上那几个字。
    var title: String {
        switch self {
        case .plusEqual: "+="
        case .harman: "哈曼"
        case .pop: "流行"
        case .rock: "摇滚"
        case .jazz: "爵士"
        case .classical: "古典"
        case .vocal: "人声"
        case .bass: "低音"
        case .electronic: "电子"
        }
    }
}

/// 用户自己命名的一条曲线。增删改是 Session 的执行，这个类型只是值。
struct EQUserPreset: Equatable, Codable {
    var id: String
    var name: String
    var gains: EQGains
}

/// 横滑那一排卡：自定义 → 用户命名 → 9 个内置。判断产它，页面消费它。
enum EQPresetCard: Equatable {
    case custom
    case user(EQUserPreset)
    case builtIn(EQBuiltInPreset)
}

/// 节点该干活还是该让开。判断吐这个，不吐 `Bool`。
enum EffectsNodeBypass: Equatable {
    case bypass
    case engage
}

/// 连线结果。失败怎么对人说由界面决定；执行层只照做（接回干声）。
enum EQConnectOutcome: Equatable {
    case connected
    case fellBackToDry
}

/// EQ + 速率此刻的样子。活状态在 `EffectsSession`；这是它推给界面 / 锁屏的一份。
///
/// ⚠️ `connectOutcome` / `isDirty` **不进存档**：前者是这次连线的结果，后者是「保存」键亮不亮。
struct EffectsSettings: Equatable {
    var selection: EQSelection
    var gains: EQGains
    var customGains: EQGains
    var userPresets: [EQUserPreset]
    var rate: PlaybackRate
    var connectOutcome: EQConnectOutcome
    var isDirty: Bool
}

/// 落盘那一份。和活状态分开，免得连线结果、脏标记被写进偏好。
struct EffectsArchive: Equatable, Codable {
    var selection: EQSelection
    var gains: EQGains
    var customGains: EQGains
    var userPresets: [EQUserPreset]
    var rate: PlaybackRate

    /// 新装：自定义 + 平线 + 1×。
    static let factory = EffectsArchive(
        selection: .custom,
        gains: .flat,
        customGains: .flat,
        userPresets: [],
        rate: .x1
    )
}
