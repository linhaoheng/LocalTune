import SnapKit
import UIKit

/// 速度页。分组列表：五档打勾，**最后一行是「自定义速度」**（点开敲数字，不是滑杆）。
/// 皮走令牌，不跟 EQ 一起涂黑。
final class PlaybackSpeedViewController: BaseViewController, UITableViewDataSource, UITableViewDelegate {

    private let session: EffectsSession
    private let presets = PlaybackRate.presets
    private let tableView = UITableView(frame: .zero, style: .grouped)

    init(session: EffectsSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        title = "速度"
        largeTitleDisplayMode = .always
    }

    required init?(coder: NSCoder) {
        // 本页只由代码构造 —— 从 nib / storyboard 解档是写错了：调试期当场停下，正式版返回 nil。
        assertionFailure("PlaybackSpeedViewController 只由代码构造，不该走 init(coder:)")
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = AppColor.groupedPageBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        view.addSubview(tableView)
        tableView.snp.makeConstraints { $0.edges.equalToSuperview() }

        session.changes
            .map(\.rate)
            .distinctUntilChanged()
            .subscribe(onNext: { [weak self] _ in
                self?.tableView.reloadData()
            })
            .disposed(by: disposeBag)
    }

    // MARK: - 表格

    /// 这一行是不是那五档之一 —— 表格三个口（行数、取格、点选）都从这一个判据走。
    ///
    /// ⚠️ 别在别处再写 `row < presets.count`：加第七行时那种写法只会漏一处，而且是静默的。
    private func isPresetRow(_ row: Int) -> Bool {
        presets.indices.contains(row)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        presets.count + 1
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        let rate = session.current.rate
        var content = UIListContentConfiguration.cell()

        if isPresetRow(indexPath.row) {
            let preset = presets[indexPath.row]
            content.text = preset.display
            cell.accessoryType = rate == preset ? .checkmark : .none
        } else {
            content.text = customTitle(for: rate)
            // 当前速度不是那五档之一 ⇒ 勾打在「自定义速度」上。
            cell.accessoryType = rate.isPreset ? .none : .checkmark
        }

        cell.contentConfiguration = content
        cell.tintColor = AppColor.accent
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard isPresetRow(indexPath.row) else {
            promptCustomRate()
            return
        }
        session.setRate(presets[indexPath.row])
    }

    // MARK: - 自定义速度

    /// 「自定义速度」，**当前速度不是那五档时**后面跟「（1.35）」。
    ///
    /// ⚠️ 括号里就是**此刻生效**的那个数 —— 没有第二份"上次输过的"。
    /// 选回某一档预置之后，这行就退回光秃秃四个字：这一行此刻不指向任何速度。
    private func customTitle(for rate: PlaybackRate) -> String {
        rate.isPreset ? "自定义速度" : "自定义速度（\(rate.display)）"
    }

    /// 敲数字的弹窗（不是滑杆）。确认键亮不亮跟提交时用的是**同一个**判据 `PlaybackRate.parse`。
    private func promptCustomRate() {
        AppAlert.prompt(
            from: self,
            title: "自定义速度",
            message: "0.1 到 4 之间，最多两位小数",
            placeholder: PlaybackRate.x1.display,
            initialText: session.current.rate.display,
            keyboardType: .decimalPad,
            confirmTitle: "完成",
            isValid: { PlaybackRate.parse($0) != nil },
            onConfirm: { [weak self] text in
                guard let rate = PlaybackRate.parse(text) else { return }
                self?.session.setRate(rate)
            }
        )
    }
}
