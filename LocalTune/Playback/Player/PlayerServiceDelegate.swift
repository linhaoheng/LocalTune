import AVFAudio
import Foundation
import SFBAudioEngine

/// 引擎回调的**转发器** —— 把库的回调**立刻**翻成贴好号的 `PlayerService.Event`。
///
/// 库要求 delegate 是个 ObjC 对象（`NSObject` + `AudioPlayer.Delegate`），而 `PlayerService` 不是 ——
/// 中间垫这一层。单独一个文件，是为了守住 `PlayerService` ≤ 400 行。
///
/// ⚠️ 它**只做翻译、不做判断** —— "这条事件该怎么处理"全在 `PlayManager` 那边。
/// 它唯一要认的是**事件属于哪一张号**（`DecoderTickets`），因为只有在库的回调里才知道是哪个解码器。
final class PlayerServiceDelegate: NSObject, AudioPlayer.Delegate {

    /// 贴好号的事件往哪儿送（`PlayerService.deliver`，它会回主线程）。
    var onEvent: ((PlayerService.Event) -> Void)?

    /// 格式变了：只重连已有节点，返回库该把 source 接到的那个头。
    ///
    /// 🔴 这里不读 Session、不改增益（库在引擎队列上叫这条）。
    var onReconnect: ((AVAudioEngine, AVAudioNode, AVAudioFormat) -> AVAudioNode)?

    /// 引擎级异步错 —— 交给 `PlayerService` 做 400ms 宽限，**不**在这儿直接报失败。
    var onEngineError: ((Error) -> Void)?

    private let tickets: DecoderTickets

    init(tickets: DecoderTickets) {
        self.tickets = tickets
    }

    /// 播放态是**引擎**的事，不属于某一个解码器 ⇒ 贴在响的那首的号。
    func audioPlayer(
        _ audioPlayer: AudioPlayer,
        playbackStateChanged playbackState: AudioPlayer.PlaybackState
    ) {
        emit(.status(Self.status(playbackState)), ticket: tickets.audibleTicket)
    }

    /// 解码器开始解码 / 开始出声 —— 哪一步算「这一首真的开始了」由 `decoderMilestoneMeansReady` 判断
    /// （立即播放的看开始解码，排着的下一首看开始出声）。
    ///
    /// 开始出声这条，库是按"这一帧真正被渲染的时刻"派发的（`AudioPlayer.mm` 里 `dispatch_after(hostTime)`），
    /// 所以无缝换歌时界面和耳朵对得上。
    ///
    /// ⚠️ 时长**可能还没有**，但"开始了"这件事跟时长无关，**照样要报**：
    /// 状态就是靠这一条从「装载中」出来的。
    func audioPlayer(_ audioPlayer: AudioPlayer, decodingStarted decoder: PCMDecoding) {
        reportReady(decoder, at: .decodingStarted)
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, renderingStarted decoder: PCMDecoding) {
        reportReady(decoder, at: .renderingStarted)
    }

    /// 等候的、在响的**全都放完了**。
    ///
    /// 🔴 实现了这一条，库就**不停引擎、也不再补发「停了」**（`AudioPlayer.mm` 里 `shouldStop = false`）——
    /// 所以这是"放完"唯一的信号，位置报告也得靠它收尾（见 `PlayerService.updatePositionReporting`）。
    /// 接着放还是停引擎由 `PlayManager.handleFinished` 决定 —— 它不叫 `stop()`，引擎就一直空转。
    func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        emit(.finished, ticket: tickets.audibleTicket)
    }

    /// **这一首放不了** —— 解码器打开失败 / 解码中途崩了，都走这条。
    ///
    /// ⚠️ 库把「正常取消」和「真失败」分成两条：换歌时旧解码器被取消走
    /// `decoderCanceled`（**不带错误**），这里这条**带错误**。前者是正常的，我们**不接**它 ——
    /// 不实现就是忽略，那不是错。
    ///
    /// 排着的下一首提前打开失败也走这条，号会告诉 `PlayManager` 它是谁的。
    func audioPlayer(
        _ audioPlayer: AudioPlayer,
        decodingAborted decoder: PCMDecoding,
        error: Error,
        framesRendered: AVAudioFramePosition
    ) {
        guard let ticket = tickets.ticket(for: decoder) else { return }
        emit(.failed(error), ticket: ticket)
    }

    /// 格式变了：库已经拆掉 source→mixer 中间那段。我们只重连，返回 EQ 头。
    func audioPlayer(
        _ audioPlayer: AudioPlayer,
        reconfigureProcessingGraph engine: AVAudioEngine,
        with format: AVAudioFormat
    ) -> AVAudioNode {
        onReconnect?(engine, audioPlayer.mainMixerNode, format) ?? audioPlayer.sourceNode
    }

    /// 引擎级异步错 —— 混着会自愈的（路由 / 打断）。宽限在 `PlayerService`。
    func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: Error) {
        onEngineError?(error)
    }

    // MARK: - 私有

    private func emit(_ kind: PlayerService.Event.Kind, ticket: Int) {
        onEvent?(PlayerService.Event(ticket: ticket, kind: kind))
    }

    private func reportReady(_ decoder: PCMDecoding, at milestone: DecoderMilestone) {
        guard let ticket = tickets.readyTicket(for: decoder, at: milestone) else { return }
        emit(.ready(Self.duration(of: decoder)), ticket: ticket)
    }

    /// 时长从**这个解码器自己**算，不读 `audioPlayer.totalTime`：
    /// 后者读的是库里"第一个活着的解码器"，换歌边界那一下它可能还是上一首。
    ///
    /// `nil` ＝ 这一份算不出时长（帧数未知 —— 库用 `unknownFrameLength`（-1）表示 / 采样率没有）。
    private static func duration(of decoder: PCMDecoding) -> TimeInterval? {
        let frames = decoder.length
        let sampleRate = decoder.processingFormat.sampleRate
        guard frames > 0, sampleRate > 0 else { return nil }
        return TimeInterval(frames) / sampleRate
    }

    /// 库的三种播放态 → `ReportedPlaybackStatus`。
    ///
    /// ⚠️ `@unknown default` 不是摆设：库是外部依赖，将来它加一个态，这里会**编译警告**
    /// 而不是静默当成"停了" —— 那时候我们该回来重新想。
    private static func status(_ state: AudioPlayer.PlaybackState) -> ReportedPlaybackStatus {
        switch state {
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        @unknown default: .stopped
        }
    }
}
