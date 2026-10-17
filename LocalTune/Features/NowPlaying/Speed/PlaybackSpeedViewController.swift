import SnapKit
import UIKit

/// 速度页。分组列表，五档打勾；皮走令牌，不跟 EQ 一起涂黑。
final class PlaybackSpeedViewController: BaseViewController, UITableViewDataSource, UITableViewDelegate {

    private let session: EffectsSession
    private let rates = PlaybackRate.allCases
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
        tableView.backgroundColor = AppColor.secondaryPageBackground
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

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rates.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        let rate = rates[indexPath.row]
        var content = UIListContentConfiguration.cell()
        content.text = rate.title
        cell.contentConfiguration = content
        cell.accessoryType = rate == session.current.rate ? .checkmark : .none
        cell.tintColor = AppColor.accent
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        session.setRate(rates[indexPath.row])
    }
}
