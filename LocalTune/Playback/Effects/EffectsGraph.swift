import AVFAudio
import Foundation

/// source → EQ → 变速 → mixer。不 import SFB，不读 Session。
///
/// 连线套 ObjC 异常；失败把 source 接回 mixer（干声），不死机、不静音。
///
/// ⚠️ **两个节点会换人**（`discardNodes()`）—— 所以是 `private(set) var` 不是 `let`：
/// 媒体服务重启后，挂在旧引擎上的 `AVAudioUnitEQ` / `AVAudioUnitTimePitch` **一样作废**
/// （Apple QA1749：连同 `AVAudioEngine` **和它的节点**一起重造）。见 `discardNodes()`。
final class EffectsGraph {

    private(set) var eq = EQUnit()
    private(set) var stretch = TimeStretchUnit()

    /// 两个节点已经 attach 过。格式变了只重连，不再 attach。
    private(set) var isInstalled = false

    /// **媒体服务重启**：挂在引擎上的节点全部作废 ⇒ 连同"装过"这件事一起丢掉，
    /// 下次 `install` 从零 attach / 连线。
    ///
    /// 🔴 **不丢会静默失效**：`isInstalled` 不复位的话，新引擎的 `install` 会**跳过 attach**，
    /// 而那两个节点还挂在**已经没了的**旧引擎上 ⇒ `connect` 失败 ⇒ 回接干声
    /// （不报错、也不生效 —— 用户只会觉得"EQ 不管用了"）。
    ///
    /// ⚠️ 增益 / 速率**不在这儿**：数字活在 `EffectsSession`，由 `PlayerService` 在建引擎那一步
    /// `apply(eq:rate:)` 重新灌进来（见 `PlayerService.engine()`）。这里只换节点。
    func discardNodes() {
        eq = EQUnit()
        stretch = TimeStretchUnit()
        isInstalled = false
    }

    /// 第一次：attach 两个节点，再连整条链。
    func install(
        engine: AVAudioEngine,
        source: AVAudioNode,
        mixer: AVAudioNode
    ) -> EQConnectOutcome {
        attachIfNeeded(to: engine)
        engine.disconnectNodeInput(mixer)
        return connectFull(engine: engine, source: source, mixer: mixer, format: nil)
    }

    /// 格式变了：库已经拆掉这段。只重连已有节点，返回 EQ（库会把 source 接到返回值上）。
    ///
    /// 🔴 不读 Session、不改增益 —— 这个回调不在主线程。
    func reconnect(
        engine: AVAudioEngine,
        mixer: AVAudioNode,
        format: AVAudioFormat
    ) -> (head: AVAudioNode, outcome: EQConnectOutcome) {
        attachIfNeeded(to: engine)
        if connect(engine, from: eq.node, to: stretch.node, format: format),
           connect(engine, from: stretch.node, to: mixer, format: format) {
            return (eq.node, eqConnectOutcome(succeeded: true))
        }
        return (mixer, eqConnectOutcome(succeeded: false))
    }

    func apply(eq gains: EQGains, rate: PlaybackRate) {
        eq.apply(gains)
        stretch.apply(rate)
    }

    private func attachIfNeeded(to engine: AVAudioEngine) {
        guard !isInstalled else { return }
        engine.attach(eq.node)
        engine.attach(stretch.node)
        isInstalled = true
    }

    private func connectFull(
        engine: AVAudioEngine,
        source: AVAudioNode,
        mixer: AVAudioNode,
        format: AVAudioFormat?
    ) -> EQConnectOutcome {
        let ok = connect(engine, from: source, to: eq.node, format: format)
            && connect(engine, from: eq.node, to: stretch.node, format: format)
            && connect(engine, from: stretch.node, to: mixer, format: format)
        if ok { return eqConnectOutcome(succeeded: true) }
        _ = connect(engine, from: source, to: mixer, format: format)
        return eqConnectOutcome(succeeded: false)
    }

    private func connect(
        _ engine: AVAudioEngine,
        from source: AVAudioNode,
        to destination: AVAudioNode,
        format: AVAudioFormat?
    ) -> Bool {
        var error: NSError?
        return LTCatchAudioEngineConnect(engine, source, destination, format, &error)
    }
}
