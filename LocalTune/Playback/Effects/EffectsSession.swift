import Foundation
import RxRelay
import RxSwift

/// 当前 EQ + 速率的唯一活状态。持久化走 `AppSettings`（滑块合并 300ms）。
///
/// 不碰 `AVAudioEngine`：数字交给外面的 `apply`（装配层接到 `PlayerService`）。
@MainActor
final class EffectsSession {

    /// 界面订这一份。`BehaviorRelay` ⇒ 订阅当下就有当前值。
    var changes: Observable<EffectsSettings> { relay.asObservable() }

    /// 同步读 —— 锁屏拼快照时用，不当成第二条真相。
    var current: EffectsSettings { relay.value }

    var rate: PlaybackRate { relay.value.rate }

    private let store: AppSettings
    private let applyToEngine: (EQGains, PlaybackRate) -> Void
    private let relay: BehaviorRelay<EffectsSettings>
    private var persistWork: DispatchWorkItem?
    private static let persistDelay: TimeInterval = 0.3

    init(settings: AppSettings, apply: @escaping (EQGains, PlaybackRate) -> Void) {
        store = settings
        applyToEngine = apply
        let initial = effectsSettings(from: settings.effectsArchive)
        relay = BehaviorRelay(value: initial)
        applyToEngine(initial.gains, initial.rate)
    }

    func selectBuiltIn(_ preset: EQBuiltInPreset) {
        commit(
            persist: .now,
            apply: true
        ) { settings in
            settings.selection = .builtIn(preset)
            settings.gains = EQBuiltInGains.gains(for: preset)
            settings.isDirty = false
        }
    }

    func selectCustom() {
        commit(persist: .now, apply: true) { settings in
            settings.selection = .custom
            settings.gains = settings.customGains
            settings.isDirty = false
        }
    }

    func selectUser(id: String) {
        guard let item = current.userPresets.first(where: { $0.id == id }) else { return }
        commit(persist: .now, apply: true) { settings in
            settings.selection = .user(id: id)
            settings.gains = item.gains
            settings.isDirty = false
        }
    }

    func setBand(index: Int, gain: Float) {
        guard (0..<EQSpec.bandCount).contains(index) else { return }
        commit(persist: .soon, apply: true) { settings in
            var bands = settings.gains.bands
            if bands.count != EQSpec.bandCount {
                bands = Array(repeating: 0, count: EQSpec.bandCount)
            }
            bands[index] = gain
            let next = clampedEQGains(bands: bands, preamp: settings.gains.preamp)
            settings.gains = next
            settings.customGains = next
            settings.selection = eqSelection(afterBandEdit: settings.selection)
            settings.isDirty = true
        }
    }

    func setPreamp(_ value: Float) {
        commit(persist: .soon, apply: true) { settings in
            let next = clampedEQGains(bands: settings.gains.bands, preamp: value)
            settings.gains = next
            settings.customGains = next
            settings.selection = eqSelection(afterBandEdit: settings.selection)
            settings.isDirty = true
        }
    }

    func resetEQ() {
        // 频段清零，且 `eqManage+128 = 1` ⇒ 一张卡都不亮。
        commit(persist: .now, apply: true) { settings in
            let next = resetEQGains()
            settings.gains = next
            if settings.selection == .custom {
                settings.customGains = next
            }
            settings.selection = .none
            settings.isDirty = false
        }
    }

    func saveUserPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commit(persist: .now, apply: false) { settings in
            let item = EQUserPreset(id: UUID().uuidString, name: trimmed, gains: settings.gains)
            settings.userPresets.append(item)
            settings.selection = .user(id: item.id)
            settings.isDirty = false
        }
    }

    func deleteUserPreset(id: String) {
        commit(persist: .now, apply: true) { settings in
            settings.userPresets.removeAll { $0.id == id }
            if case .user(let selected) = settings.selection, selected == id {
                settings.selection = .custom
                settings.gains = settings.customGains
                settings.isDirty = false
            }
        }
    }

    func setRate(_ rate: PlaybackRate) {
        commit(persist: .now, apply: true) { settings in
            settings.rate = rate
        }
    }

    func noteConnect(_ outcome: EQConnectOutcome) {
        commit(persist: .none, apply: false) { $0.connectOutcome = outcome }
    }

    private enum Persist {
        case now
        case soon
        case none
    }

    private func commit(
        persist: Persist,
        apply: Bool,
        mutate: (inout EffectsSettings) -> Void
    ) {
        var next = relay.value
        mutate(&next)
        relay.accept(next)
        if apply {
            applyToEngine(next.gains, next.rate)
        }
        switch persist {
        case .now: persistNow(next)
        case .soon: persistSoon(next)
        case .none: break
        }
    }

    private func persistSoon(_ settings: EffectsSettings) {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.store.effectsArchive = effectsArchive(from: settings)
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.persistDelay, execute: work)
    }

    private func persistNow(_ settings: EffectsSettings) {
        persistWork?.cancel()
        persistWork = nil
        store.effectsArchive = effectsArchive(from: settings)
    }
}
