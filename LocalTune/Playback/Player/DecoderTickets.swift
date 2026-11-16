import Foundation
import SFBAudioEngine

/// 「这个解码器是哪一张号」+「现在在响的是哪一张号」—— 引擎事件贴号的唯一依据。
///
/// 🔴 为什么不能像以前那样只记「最近一次点播的号」：无缝接歌时**同时有两个解码器在路上**
/// （正在响的这首 + 排着的下一首），库回调时只告诉我们"是哪个解码器"。
/// 拿"最近一次"去贴，下一首提前打开的事件会被记到当前这首的账上。
///
/// **谁写谁读**：`PlayerService` 在它自己那条队列上登记；库在**它自己的线程**上回调时查 ⇒ 带锁。
///
/// ⚠️ **解码器对象是被持有的**，不是只记个地址：对象释放后地址会被新对象复用，
/// 只记地址就可能把旧号贴到新解码器上。
///
/// ⚠️ **只有一条清理规则**：在响的号前进到 T ⇒ 号比 T 小的全部丢掉（它们的事件一律过期）。
/// 不在"取消 / 播完"回调里逐个删 —— 被 `clearQueue` 清掉的解码器**根本没有回调**，
/// 逐个删一定会漏；按号清不会。代价是排过又撤掉的几个解码器多活到下一次换歌。
final class DecoderTickets {

    private let lock = NSLock()
    private var entries: [(decoder: PCMDecoding, ticket: Int)] = []
    private var audible = 0

    /// 现在在响的那首的号 —— 不带解码器的事件（播放态变了 / 全部放完）贴这个。
    var audibleTicket: Int {
        lock.lock()
        defer { lock.unlock() }
        return audible
    }

    /// 立即播放：它一交给库就是在响的那首。
    func registerImmediate(_ decoder: PCMDecoding, ticket: Int) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((decoder, ticket))
        advanceAudible(to: ticket)
    }

    /// 排下一首：要等它**真的开始出声**（`readyTicket`）才算在响的。
    func registerQueued(_ decoder: PCMDecoding, ticket: Int) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((decoder, ticket))
    }

    /// 这个解码器的号。`nil` ＝ 不认识 / 已经过期被清掉了。
    func ticket(for decoder: PCMDecoding) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return ticketLocked(for: decoder)
    }

    /// 解码器走到了 `milestone` —— 算「这一首真的开始了」就让它成为在响的那首、返回它的号；不算 ⇒ `nil`。
    /// 算不算是判断，在 `decoderMilestoneMeansReady`。
    ///
    /// 「查号 → 判断 → 前进」必须在同一把锁里：分开做，中间插进来一次立即播放，
    /// 就会把在响的号往回拨。
    func readyTicket(for decoder: PCMDecoding, at milestone: DecoderMilestone) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let ticket = ticketLocked(for: decoder),
              decoderMilestoneMeansReady(milestone, ticket: ticket, audibleTicket: audible) == .started
        else { return nil }
        advanceAudible(to: ticket)
        return ticket
    }

    // MARK: - 私有（调用方已持锁）

    private func ticketLocked(for decoder: PCMDecoding) -> Int? {
        entries.first { $0.decoder === decoder }?.ticket
    }

    private func advanceAudible(to ticket: Int) {
        audible = ticket
        entries.removeAll { $0.ticket < ticket }
    }
}
