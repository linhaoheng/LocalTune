import UIKit
import UniformTypeIdentifiers

/// 曲库页**导入协作者** —— 「打开文件」和「扫描本地音频」两条，加上选完文件之后那一下。
///
/// 页面私有协作者：从"选文件"到"把进度换成结果"是一条完整的链，都收在这里；
/// 弹文件选择器的出口是页面。
@MainActor
final class SongsImportController: NSObject {

    // MARK: - 依赖

    /// 导入 / 扫描的入口 —— 两条流程都只有这一个出口。
    private let importService: ImportService

    /// 弹文件选择器的出口。
    private weak var page: UIViewController?

    init(importService: ImportService, page: UIViewController) {
        self.importService = importService
        self.page = page
    }

    // MARK: - 入口

    /// 「打开文件」：只选**音频文件**（规格定死：不选文件夹），可多选。
    ///
    /// ⚠️ `asCopy: false`（open-in-place）是**照 primuse 的选法**（出处：
    /// `SourceTypeSelectionView.swift:1500-1517`）：它要拿到"活的安全域 URL"，
    /// 由我们自己去读、去拷；`asCopy: true` 会先让系统导出一份到沙盒，
    /// 某些第三方网盘在那一步交出来的是**几十字节的占位文件**，导入必然失败。
    ///
    /// ⚠️ 空状态那个「导入歌曲」按钮也走这个入口（见 `SongsEmptyStateController`）
    /// —— 两个入口一件事，不各写一份。
    func presentFilePicker() {
        guard let page else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        page.present(picker, animated: true)
    }

    /// 「扫描本地音频」—— 由「更多」菜单调。
    func startScan() {
        Task { [weak self] in
            guard let self else { return }
            let result = await self.importService.scanLibrary { HUD.showProgress($0) }
            self.finish(with: result)
        }
    }

    // MARK: - 私有

    private func startImport(_ urls: [URL]) {
        Task { [weak self] in
            guard let self else { return }
            let result = await self.importService.importFiles(urls) { HUD.showProgress($0) }
            self.finish(with: result)
        }
    }

    /// 跑完那一下：**把进度换成结果提示**（不是先 hide 再 show —— 那样会闪一下）。
    ///
    /// 提示几秒后自己消失，这里不用管。有失败就报成"出错"语气（图标不同），否则报成功。
    private func finish(with result: ImportResult) {
        HUD.showMessage(
            result.hudMessage,
            detail: result.hudDetail,
            note: result.hudNote,
            style: result.failed > 0 ? .error : .success
        )
    }
}

// MARK: - 选文件

extension SongsImportController: UIDocumentPickerDelegate {

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard !urls.isEmpty else { return }
        startImport(urls)
    }
}
