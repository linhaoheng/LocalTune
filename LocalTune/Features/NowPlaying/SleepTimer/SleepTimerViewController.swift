import RxSwift
import SnapKit
import UIKit

/// 定时关闭。档位和「放完这首再停」能叠。皮跟速度页同一套分组表。
final class SleepTimerViewController: BaseViewController, UITableViewDataSource, UITableViewDelegate {

    private let switchReuse = "switch"

    private let session: SleepTimerSession
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let finishSwitch = UISwitch()
    private let footerLabel = UILabel()
    private let footerContainer = UIView()
    private var rendered: SleepTimerSnapshot?

    init(session: SleepTimerSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        title = "定时关闭"
        largeTitleDisplayMode = .always
    }

    required init?(coder: NSCoder) {
        // 本页只由代码构造 —— 从 nib / storyboard 解档是写错了：调试期当场停下，正式版返回 nil。
        assertionFailure("SleepTimerViewController 只由代码构造，不该走 init(coder:)")
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = AppColor.secondaryPageBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(SleepTimerOptionCell.self, forCellReuseIdentifier: SleepTimerOptionCell.reuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: switchReuse)
        // 行高 50。自动行高会压得太矮。
        tableView.rowHeight = AppMetrics.sleepTimerRowHeight
        view.addSubview(tableView)
        tableView.snp.makeConstraints { $0.edges.equalToSuperview() }

        finishSwitch.onTintColor = AppColor.accent
        finishSwitch.addTarget(self, action: #selector(finishChanged), for: .valueChanged)

        footerLabel.numberOfLines = 0
        footerLabel.font = AppFont.sleepTimerFooter
        footerLabel.textColor = AppColor.subtitle
        footerContainer.addSubview(footerLabel)
        footerLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(AppMetrics.sleepTimerFooterTop)
            make.leading.equalToSuperview().offset(AppMetrics.sleepTimerFooterInset)
            make.trailing.equalToSuperview().offset(-AppMetrics.sleepTimerFooterInset)
            make.bottom.equalToSuperview().offset(-AppMetrics.sleepTimerFooterBottom)
        }

        applySnapshot(session.current)
        session.changes
            .skip(1)
            .subscribe(onNext: { [weak self] snapshot in
                self?.applySnapshot(snapshot)
            })
            .disposed(by: disposeBag)
        bindCountdownClock()
    }

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? rows.count : 1
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 1 {
            let cell = tableView.dequeueReusableCell(withIdentifier: switchReuse, for: indexPath)
            paintSwitch(cell)
            return cell
        }
        let dequeued = tableView.dequeueReusableCell(
            withIdentifier: SleepTimerOptionCell.reuseID,
            for: indexPath
        )
        guard let cell = dequeued as? SleepTimerOptionCell else {
            assertionFailure("这一行必须是 SleepTimerOptionCell")
            return dequeued
        }
        paintOption(cell, rows[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        section == 1 ? footerContainer : nil
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        guard section == 1 else { return .leastNonzeroMagnitude }
        let width = tableView.bounds.width - AppMetrics.sleepTimerFooterInset * 2
        let size = footerLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return size.height + AppMetrics.sleepTimerFooterTop + AppMetrics.sleepTimerFooterBottom
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0 else { return }
        let row = rows[indexPath.row]
        if case .custom = row {
            promptCustom()
            return
        }
        session.select(row)
    }

    private var rows: [SleepSelection] {
        [.off] + SleepPreset.allCases.map { .preset($0) } + [.custom(minutes: 0)]
    }

    private func isCurrent(_ row: SleepSelection) -> Bool {
        switch (row, session.current.selection) {
        case (.off, .off): true
        case (.preset(let left), .preset(let right)): left == right
        case (.custom, .custom): true
        default: false
        }
    }

    private func paintOption(_ cell: SleepTimerOptionCell, _ row: SleepSelection) {
        let selected = isCurrent(row)
        cell.show(title: row.title, remaining: selected ? remainingText() : nil)
        cell.accessoryType = selected ? .checkmark : .none
        cell.tintColor = AppColor.accent
    }

    private func paintSwitch(_ cell: UITableViewCell) {
        var content = UIListContentConfiguration.cell()
        content.text = "播放完整首歌后停止"
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessoryType = .none
        cell.accessoryView = finishSwitch
    }

    private func footerText(finishAfterSong: Bool) -> String {
        finishAfterSong
            ? "计时结束后，播放完整首歌后再停止"
            : "计时结束后，立即停止播放"
    }

    private func applySnapshot(_ snapshot: SleepTimerSnapshot) {
        let previous = rendered
        rendered = snapshot
        finishSwitch.isOn = snapshot.finishAfterSong
        footerLabel.text = footerText(finishAfterSong: snapshot.finishAfterSong)
        guard let previous else {
            tableView.reloadData()
            return
        }
        if previous.selection != snapshot.selection || previous.phase != snapshot.phase {
            tableView.reloadSections(IndexSet(integer: 0), with: .none)
        }
        // 开关那组不许 reload：共用的 UISwitch 正在被按，整组重建会卡死。
        // 脚注只改字 + beginUpdates 量高度（`reloadSections` 那种写法每次都新建开关；我们是同一颗）。
        if previous.finishAfterSong != snapshot.finishAfterSong {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }

    private func bindCountdownClock() {
        session.changes
            .map { snapshot -> Bool in
                if case .countingDown = snapshot.phase { return true }
                return false
            }
            .distinctUntilChanged()
            .flatMapLatest { ticking -> Observable<Int> in
                ticking
                    ? Observable<Int>.interval(.seconds(1), scheduler: MainScheduler.instance)
                    : .empty()
            }
            .subscribe(onNext: { [weak self] _ in
                self?.refreshCountdown()
            })
            .disposed(by: disposeBag)
    }

    private func refreshCountdown() {
        guard let index = rows.firstIndex(where: isCurrent),
              let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? SleepTimerOptionCell
        else { return }
        paintOption(cell, rows[index])
    }

    private func remainingText() -> String? {
        guard let seconds = sleepDisplayedRemaining(now: Date(), phase: session.current.phase) else {
            return nil
        }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func promptCustom() {
        AppAlert.prompt(
            from: self,
            title: "自定义分钟",
            placeholder: "分钟",
            initialText: session.lastCustomMinutes > 0 ? "\(session.lastCustomMinutes)" : nil,
            keyboardType: .numberPad,
            confirmTitle: "完成",
            onConfirm: { [weak self] text in
                let value = Int(text) ?? 0
                self?.session.select(.custom(minutes: value))
            }
        )
    }

    @objc private func finishChanged() {
        session.setFinishAfterSong(finishSwitch.isOn)
    }
}
