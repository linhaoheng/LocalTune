import Foundation
import Intents

/// 主 App 侧 `INPlayMediaIntent`：解析放行 + 匹配走 Policy + 起播走 Bridge。
///
/// 桥由 `AppDelegate` **构造注入**（系统入口拿不到 `AppServices` 的 init 缝）。
/// iOS 14+ 由 `AppDelegate.application(_:handlerFor:)` 交出本类；**不做**独立
/// Intents Extension —— 主 App 这条路已能处理播放意图，少一个 target。
final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {

    private let bridge: LocalTuneIntentBridge

    init(bridge: LocalTuneIntentBridge) {
        self.bridge = bridge
    }

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        let items = intent.mediaItems ?? []
        completion(items.map { INPlayMediaMediaItemResolutionResult.success(with: $0) })
    }

    func handle(
        intent: INPlayMediaIntent,
        completion: @escaping (INPlayMediaIntentResponse) -> Void
    ) {
        Task { @MainActor in
            let ok = await handlePlayMedia(intent)
            completion(INPlayMediaIntentResponse(code: ok ? .success : .failure, userActivity: nil))
        }
    }

    /// - Returns: 是否起播 / 续播成功。
    @MainActor
    private func handlePlayMedia(_ intent: INPlayMediaIntent) async -> Bool {
        do {
            try await bridge.awaitReady()
            let library = try bridge.makeLibrary()
            let target = mediaPlayTarget(
                request: MediaPlayRequest(intent),
                library: library,
                session: bridge.currentSession()
            )
            try bridge.apply(target)
            return true
        } catch {
            // 这条路的应答**只有**成 / 不成两态，没有放我们自己文案的位置 ——
            // 说话的是 Siri。所以能做的就是「失败就报失败、不假成功」：`false` → 上面回 `.failure`。
            // （能给用户读的那几句人话在**快捷指令**那条路，那条路是我们自己的 `AppIntent`。）
            return false
        }
    }
}

extension MediaPlayRequest {
    init(_ intent: INPlayMediaIntent) {
        if let item = intent.mediaItems?.first {
            self = .mediaItem(
                kind: MediaPlayRequest.ItemKind(item.type),
                identifier: item.identifier ?? "",
                title: item.title ?? ""
            )
            return
        }
        if let search = intent.mediaSearch {
            let name = search.mediaName ?? search.artistName ?? ""
            self = .search(kind: MediaPlayRequest.ItemKind(search.mediaType), name: name)
            return
        }
        self = .bare
    }
}

extension MediaPlayRequest.ItemKind {
    init(_ type: INMediaItemType) {
        switch type {
        case .playlist: self = .playlist
        case .album: self = .album
        case .song, .music: self = .song
        default: self = .other
        }
    }
}
