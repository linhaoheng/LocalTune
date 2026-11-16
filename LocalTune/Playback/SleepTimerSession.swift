import Foundation
import RxRelay
import RxSwift

/// 睡眠定时的唯一活状态。
///
/// 不碰引擎：立刻停走外面注入的 `pause`；「等这首完」只锁曲目 id，播完由总管来问。
/// 持久化只存开关。倒计时、锁、自定义分钟都不落盘 —— 杀进程就没了。
///
/// ## 线程
///
/// **全在主线程**：选档、到期、切歌通知都从界面 / `PlayManager` 进来。
@MainActor
final class SleepTimerSession {

    var changes: Observable<SleepTimerSnapshot> { relay.asObservable() }

    var current: SleepTimerSnapshot { relay.value }

    /// 正在等这首放完 ⇒ 总管不该再给库排下一首。
    var holdsSuccessor: Bool {
        if case .holding = relay.value.phase { return true }
        return false
    }

    /// 上次自定义的分钟，只给输入框回填，不落盘。
    private(set) var lastCustomMinutes = 0

    private let store: AppSettings
    private let relay: BehaviorRelay<SleepTimerSnapshot>
    private var fireWork: DispatchWorkItem?
    /// 总管接上之前：没有正在播的歌、停也不做事。`bind` 换成真口，不是「可能没有口」。
    private var currentTrackID: () -> Track.ID? = { nil }
    private var pausePlayback: () -> Void = {}

    init(settings: AppSettings) {
        store = settings
        relay = BehaviorRelay(
            value: SleepTimerSnapshot(
                selection: .off,
                phase: .idle,
                finishAfterSong: settings.sleepFinishTrack
            )
        )
    }

    /// 总管造好之后接这两头。到期要立刻停、要不要 hold，都得问「现在在播哪首」。
    func bind(currentTrackID: @escaping () -> Track.ID?, pause: @escaping () -> Void) {
        self.currentTrackID = currentTrackID
        pausePlayback = pause
    }

    func select(_ selection: SleepSelection) {
        switch selection {
        case .off:
            cancel()
        case .preset(let preset):
            start(minutes: preset.rawValue, selection: selection)
        case .custom(let minutes):
            guard sleepMinutesAreValid(minutes) == .valid else { return }
            lastCustomMinutes = minutes
            start(minutes: minutes, selection: selection)
        }
    }

    func setFinishAfterSong(_ on: Bool) {
        store.sleepFinishTrack = on
        var next = relay.value
        next.finishAfterSong = on
        relay.accept(next)
    }

    func noteUserStarted(trackID: Track.ID) {
        guard case .holding(let held, _) = relay.value.phase else { return }
        if sleepAfterUserStarted(held: held, new: trackID) == .cancelHold {
            publishIdleKeepingSwitch()
        }
    }

    /// 这首自然结束了。对上锁 ⇒ 清掉定时、告诉总管停在这儿。
    func consumeHoldIfFinished(trackID: Track.ID?) -> Bool {
        guard case .holding(let held, _) = relay.value.phase else { return false }
        guard sleepFinishedAction(held: held, finished: trackID) == .stopHere else { return false }
        publishIdleKeepingSwitch()
        return true
    }

    private func start(minutes: Int, selection: SleepSelection) {
        cancelWork()
        let duration = TimeInterval(minutes * 60)
        let end = Date().addingTimeInterval(duration)
        let work = DispatchWorkItem { [weak self] in
            self?.expire()
        }
        fireWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        relay.accept(
            SleepTimerSnapshot(
                selection: selection,
                phase: .countingDown(end: end, selection: selection),
                finishAfterSong: relay.value.finishAfterSong
            )
        )
    }

    private func expire() {
        fireWork = nil
        switch sleepExpireAction(finishAfterSong: relay.value.finishAfterSong) {
        case .pauseNow:
            pausePlayback()
            publishIdleKeepingSwitch()
        case .holdCurrent:
            if let id = currentTrackID() {
                let selection = relay.value.selection
                relay.accept(
                    SleepTimerSnapshot(
                        selection: selection,
                        phase: .holding(trackID: id, selection: selection),
                        finishAfterSong: relay.value.finishAfterSong
                    )
                )
            } else {
                pausePlayback()
                publishIdleKeepingSwitch()
            }
        }
    }

    private func cancel() {
        cancelWork()
        publishIdleKeepingSwitch()
    }

    private func publishIdleKeepingSwitch() {
        cancelWork()
        relay.accept(
            SleepTimerSnapshot(
                selection: .off,
                phase: .idle,
                finishAfterSong: relay.value.finishAfterSong
            )
        )
    }

    private func cancelWork() {
        fireWork?.cancel()
        fireWork = nil
    }
}
