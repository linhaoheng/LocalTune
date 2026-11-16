import Foundation
import UIKit

/// 导出海报时可能出的岔子。每一种都带一句给用户看的人话。
enum LyricsPosterExportError: LocalizedError {
    /// 这个风格没有渲染器（注册表里没有它）。
    case noRenderer
    /// 渲染不出像素。
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .noRenderer, .renderFailed:
            return "海报生成失败，请换一种风格再试"
        }
    }
}

/// 把一张渲染好的海报落成文件。
///
/// 单独一个类型、不是 `LyricsPosterComposer` 的一段：导出（渲染 → 编码 → 写盘）和
/// "海报长什么样"是两件事，拆开之后状态机只管状态，导出只管落盘。
@MainActor
enum LyricsPosterExporter {

    /// 渲染一张静态海报，编码成 PNG 落进临时目录，返回文件 URL。
    ///
    /// 导出物放系统临时目录：分享和存相册都只需要它活到那一刻，系统回收也不会带走用户的东西。
    static func writeStillImage(
        style: any LyricsPosterStyleRendering,
        context: LyricsPosterRenderContext,
        baseName: String
    ) throws -> URL {
        guard let image = LyricsPosterRenderer.renderImage(style: style, context: context),
              let data = LyricsPosterRenderer.pngData(from: image) else {
            throw LyricsPosterExportError.renderFailed
        }
        let url = try makeExportDirectory().appendingPathComponent("\(baseName).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 导出物的临时目录（分享 / 存相册 / 实况照片三路共用同一个）。
    static func makeExportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(LyricsPosterMetrics.exportDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
