import Foundation
import SFBAudioEngine
import UniformTypeIdentifiers

/// 哪些文件算音频。
///
/// 🔴 **不手写白名单** —— 去问引擎要 `AudioFile.supportedPathExtensions`，再减掉两份黑名单。
/// 手写清单一定会跟引擎的真实能力脱节：常见清单里的 `aac`、`caf` 两种，
/// 引擎根本没有对应的读取类，属于"假支持"（列进去就会导入失败）。
enum AudioFileTypes {

    /// 引擎根本解不了的格式。
    static let unsupportedExtensions: Set<String> = [
        // DRM 或引擎明确拒绝的容器形式
        "m4b", "m4p", "aa", "aax",
        // Tracker 模块（`mod` / `it` / `s3m` / `xm`）。
        // ⚠️ **不是"解码器没有"** —— 引擎里有 `SFBModuleDecoder` + DUMB，解得了。
        // 真正的理由是**报不出时长**：这类格式的长度不在标签里，得另外开一次解码器跑一遍才算得出来
        //（要收就得为这四种单独补一步解码）。收进来的话列表显示「0:00」、进度条也没法拖 ⇒ 不收。
        "mod", "it", "s3m", "xm",
        // 从来没有支持过
        "ra", "ram", "mid", "midi",
    ]

    /// 再减掉「引擎的**元数据类**根本不认」的这几个扩展名。
    ///
    /// ⚠️ **这份名单目前是空的、不生效**（逐类核过引擎源码）：`thd` / `mlp` / `aifc`
    /// 在整个 SFBAudioEngine 里**一次都没出现** —— `AudioFile.supportedPathExtensions` 只来自
    /// 「有元数据读取类」的容器，AIFF 那个类也只认 `aiff` / `aif` ⇒ 它们本来就进不来，这里减的是空集。
    ///
    /// 留着它的**唯一**作用：哪天引擎（或换的库）开始认这三种格式，它们多半属于
    /// 「能解码、但报不出时长」那一类 —— 到那时这一行才真的在挡事。
    /// ⚠️ 别再照老印象说"这三种能解码"：那句话没有依据（引擎里查不到这三个名字）。
    static let withheldExtensions: Set<String> = ["thd", "mlp", "aifc"]

    /// 引擎真实支持的扩展名（小写、不带点），已减掉上面两份黑名单。
    static let supportedExtensions: Set<String> = {
        let excluded = unsupportedExtensions.union(withheldExtensions)
        let extensions = Set(AudioFile.supportedPathExtensions.map { $0.lowercased() })
            .subtracting(excluded)

        // 名单为空 = 「导入 / 扫描一首都不进」。
        //
        // ⚠️ 这是**不可能发生的状态，不是用户能处理的错误** —— 只有「引擎没链接上 /
        // 编译产物里没有解码器」才会这样，用户点什么都没用。
        // 所以这里用断言（只在 Debug 里炸，Release 是空操作）：出事的时候要让**写代码的人**
        // 当场知道，而不是写成日志、让用户对着一个「0 首」猜。
        if extensions.isEmpty {
            assertionFailure("播放引擎没有报出任何可解码的音频格式 —— 导入 / 扫描会一首都不进")
        }
        return extensions
    }()

    /// 给文件选择器用：把支持的扩展名换成系统类型。同样不手写 —— 从 `supportedExtensions` 推出来。
    static let contentTypes: [UTType] = supportedExtensions
        .sorted()
        .compactMap { UTType(filenameExtension: $0) }

    /// 这个文件是不是能导入的音频（按扩展名判断，不读文件内容）。
    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
