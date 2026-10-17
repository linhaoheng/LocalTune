import Foundation

/// 任意输入收成合法的 `EQGains`：不足 10 段补 0，超出丢掉，越界切断，非有限数当 0。
func clampedEQGains(bands: [Float], preamp: Float) -> EQGains {
    var result = Array(repeating: Float(0), count: EQSpec.bandCount)
    for index in 0..<min(bands.count, EQSpec.bandCount) {
        result[index] = clampGain(bands[index])
    }
    return EQGains(bands: result, preamp: clampGain(preamp))
}

/// 拖任一段之后亮哪张卡。内置名 / 未选中必须离开；用户命名被拖过也变成未命名自定义。
func eqSelection(afterBandEdit current: EQSelection) -> EQSelection {
    switch current {
    case .custom: return .custom
    case .none, .builtIn, .user: return .custom
    }
}

/// 平线（10 段和前级都是 0）⇒ 旁路。页面没有开关，这条就是「关」。
func eqNodeBypass(for gains: EQGains) -> EffectsNodeBypass {
    let bandsFlat = gains.bands.count == EQSpec.bandCount && gains.bands.allSatisfy { $0 == 0 }
    return bandsFlat && gains.preamp == 0 ? .bypass : .engage
}

/// 连线成不成功 → 执行层照做的那种结果。
func eqConnectOutcome(succeeded: Bool) -> EQConnectOutcome {
    succeeded ? .connected : .fellBackToDry
}

/// 横滑卡顺序：自定义 → 用户命名 → 9 个内置。
func eqPresetCards(userPresets: [EQUserPreset]) -> [EQPresetCard] {
    [.custom] + userPresets.map(EQPresetCard.user) + EQBuiltInPreset.allCases.map(EQPresetCard.builtIn)
}

/// 存档读回来之后，缺的用户预设、坏数字都收成能用的活状态。
func effectsSettings(from archive: EffectsArchive) -> EffectsSettings {
    let gains = clampedEQGains(bands: archive.gains.bands, preamp: archive.gains.preamp)
    let custom = clampedEQGains(bands: archive.customGains.bands, preamp: archive.customGains.preamp)
    let presets = archive.userPresets.map { item in
        EQUserPreset(
            id: item.id,
            name: item.name,
            gains: clampedEQGains(bands: item.gains.bands, preamp: item.gains.preamp)
        )
    }
    let selection: EQSelection
    switch archive.selection {
    case .user(let id):
        selection = presets.contains(where: { $0.id == id }) ? .user(id: id) : .custom
    case .none, .builtIn, .custom:
        selection = archive.selection
    }
    return EffectsSettings(
        selection: selection,
        gains: gains,
        customGains: custom,
        userPresets: presets,
        rate: archive.rate,
        connectOutcome: .connected,
        isDirty: false
    )
}

func effectsArchive(from settings: EffectsSettings) -> EffectsArchive {
    EffectsArchive(
        selection: settings.selection,
        gains: settings.gains,
        customGains: settings.customGains,
        userPresets: settings.userPresets,
        rate: settings.rate
    )
}

/// 重置：十条和前级摊平。
/// 选中态另走 `EQSelection.none`（`eqManage+128 = 1` ⇒ 卡全不亮），不在这里改。
func resetEQGains() -> EQGains { .flat }

private func clampGain(_ value: Float) -> Float {
    let finite = value.isFinite ? value : 0
    return min(EQSpec.maxGain, max(EQSpec.minGain, finite))
}
