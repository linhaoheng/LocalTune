import Foundation
import RxSwift

/// EQ 页：Session 的活状态翻成这一屏要画的东西。页面不存 gains。
@MainActor
final class EqualizerViewModel {

    struct Content: Equatable {
        var cards: [EQPresetCard]
        var selection: EQSelection
        var gains: EQGains
        var canSave: Bool
    }

    let content: Observable<Content>

    private let session: EffectsSession

    init(session: EffectsSession) {
        self.session = session
        content = session.changes.map(Self.content(from:)).distinctUntilChanged()
    }

    var contentNow: Content { Self.content(from: session.current) }

    func select(_ card: EQPresetCard) {
        switch card {
        case .custom: session.selectCustom()
        case .user(let item): session.selectUser(id: item.id)
        case .builtIn(let preset): session.selectBuiltIn(preset)
        }
    }

    func setBand(index: Int, gain: Float) {
        session.setBand(index: index, gain: gain)
    }

    func setPreamp(_ value: Float) {
        session.setPreamp(value)
    }

    func reset() {
        session.resetEQ()
    }

    func save(name: String) {
        session.saveUserPreset(name: name)
    }

    func deleteUserPreset(id: String) {
        session.deleteUserPreset(id: id)
    }

    static func title(of card: EQPresetCard) -> String {
        switch card {
        case .custom: "自定义"
        case .user(let item): item.name
        case .builtIn(let preset): preset.title
        }
    }

    static func isSelected(_ card: EQPresetCard, selection: EQSelection) -> Bool {
        switch (card, selection) {
        case (.custom, .custom): true
        case (.user(let item), .user(let id)): item.id == id
        case (.builtIn(let preset), .builtIn(let current)): preset == current
        default: false
        }
    }

    static func showsUserIcon(_ card: EQPresetCard) -> Bool {
        if case .user = card { return true }
        return false
    }

    static func userPresetID(of card: EQPresetCard) -> String? {
        if case .user(let item) = card { return item.id }
        return nil
    }

    private static func content(from settings: EffectsSettings) -> Content {
        Content(
            cards: eqPresetCards(userPresets: settings.userPresets),
            selection: settings.selection,
            gains: settings.gains,
            canSave: settings.isDirty
        )
    }
}
