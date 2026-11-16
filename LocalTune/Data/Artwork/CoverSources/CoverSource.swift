import Foundation

/// 「一个封面源」的形状 ＋ 一条候选 ＋ 收尾那两种说法。
///
/// ## 🔴 跟「获取歌词」那条路只借形状，不借判断
///
/// 两边长得像（`Data/…` 里一个客户端、页面在 `Features/…`），但**「拿什么词去搜」各写一份**
/// （2026-10-14 统帅定，`获取封面设计.md` §十一 已定 2）—— 实测证明了这条判断：
/// 酷狗**必须**把「歌名 艺人」拼成一串（单搜歌名第一条就是原版），
/// 而 iTunes 拼了就 **0 条**。两个引擎的脾气正好相反，共用一套回落策略只会两边都错。
///
/// ## 分层（`获取封面设计.md` §四）
///
/// 🔴 **这一层不 import `UIKit`**：它只把图取成 `Data`（跟 `LyricsSearchClient` 一个性质）——
/// 「字节 → `UIImage` ＋ 缓存」是界面那一侧的事（`Core/UI/CoverImageLoader`）。
/// 依赖方向因此没歪：`Data` 不认识屏幕，`Core` 不认识网络。
enum CoverSourceKind: String, CaseIterable, Sendable {

    /// 酷狗 —— 实测中文歌命中**最准**（搜「晴天 周杰伦」第一条就是 `叶惠美` 原版）。
    case kugou

    /// QQ音乐 —— **另一个库**，候选跟酷狗不是同一批。
    case qqMusic

    /// 列表右边那颗角标上的字。
    ///
    /// ⚠️ 它是**给人看的简称**，不是 `rawValue` —— 界面上写 `qqMusic` 是行话。
    var displayName: String {
        switch self {
        case .kugou: return "酷狗"
        case .qqMusic: return "QQ"
        }
    }
}

// MARK: - 一条候选

/// 搜到的一条候选 —— 值，零行为。
///
/// ## 🔴 两个 URL，不是一个
///
/// 列表里那一小格要的是**缩略图**（酷狗 240 档 ~30 KB、QQ 300 档 ~33 KB），
/// 挑中之后要的是**大图**（酷狗 480 档 ~95 KB、QQ 800 档 ~180 KB）。
/// 只带大图 ⇒ 一屏八行就是 1.5 MB 白流量；只带缩略图 ⇒ 存下来的封面糊。
///
/// ## 它不认识「怎么取」
///
/// 取字节是 `CoverSource` 的事（每个源自己带请求头），这一条只是"哪张图、叫什么"。
struct CoverCandidate: Equatable, Identifiable, Sendable {

    /// 哪来的 —— 列表右边那颗角标、以及"取大图时该找谁"都看它。
    let source: CoverSourceKind

    /// 歌名。
    let title: String

    /// 艺人。合唱时几个拼成一串（跟列表副行一个口径）。
    let artist: String

    /// 专辑。空串 ＝ 这一条没给。
    let album: String

    /// 年份。⚠️ **酷狗不给这个字段**（那边搜索回包里没有），所以它是可选的 ——
    /// 副行缺这一档就省掉，不编一个假的出来。
    let year: Int?

    /// 列表里那一小格用。
    let thumbnailURL: URL

    /// 挑中之后真正要的那张。
    let coverURL: URL

    /// 去重键 —— **源 ＋ 缩略图地址**。
    ///
    /// 🔴 **判的是"同一张图"，不是"同一首歌"。**
    /// 早先这里是「源 ＋ 歌名 ＋ 专辑」，于是两个字段一撞、图却不同的两条会互相吃掉：
    /// 酷狗 `album_name` 为空的条目全部落成 `kugou|歌名|`（不同艺人 · 不同唱片的同名曲全压一条），
    /// QQ 里两个都叫《精选》的专辑也会撞。而**歌名+专辑相同恰恰是用户要自己认的版本差异**
    /// （§五 的规矩），压掉就是替他做决定 —— 那一页明明是用来让人认版本的。
    ///
    /// 🔴 **刻意把源算进去：跨源不合并。**
    /// 两个源是不同的库（实测同搜《晴天》，酷狗给 `叶惠美` 原版、QQ 给《晴天》《晴天 (Live)》），
    /// 就算同名同专辑，**图也不是同一张** —— 合并掉就等于替用户扔了一张候选，
    /// 而"用户自己认版本"正是这一页的规矩（§五）。角标也会跟着没意义。
    ///
    /// 用**缩略图**地址而不是大图：两者是同一张图的两种尺寸（地址里只是换档位，见各源
    /// 的 `coverURL(_:size:)`），拿哪个都判得出同一张；而缩略图正是列表里显示的那一格 ——
    /// 用它最贴"屏幕上到底是不是重复了"。
    ///
    /// 仍然会被并掉的只有一种：**同一张图被多条条目共用**（图一样，摆两行没意义，
    /// 留源返回顺序里的第一条）。
    var id: String { "\(source.rawValue)|\(thumbnailURL.absoluteString)" }

    /// 副行：`艺人 · 专辑 · 年份`（缺哪个省哪个）。
    ///
    /// ⚠️ 这一串由候选自己给，页面**不拼字符串**（宪法 §一 Features 行）。
    var subtitle: String {
        var parts: [String] = []
        if !artist.isEmpty { parts.append(artist) }
        if !album.isEmpty { parts.append(album) }
        if let year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 一个源

/// 一个封面源 —— **只做两件事：搜 ＋ 取字节**。
///
/// ⚠️ 它**不认识**列表、不认识编辑页的草稿、不落盘、不缓存
/// （缓存是 `Core/UI/CoverImageLoader` 的事）—— 每次调用都真的发一次请求。
/// 这正是「一次搜索只发一个请求」那条限流纪律的前提（§九 第 4 条）。
///
/// 🔴 `Sendable`：协调器要**并发**问几个源，源会被捕获进并发任务里 ——
/// 实现里除了 `URLSession`（本身线程安全）不许有可变状态。
protocol CoverSource: Sendable {

    var kind: CoverSourceKind { get }

    /// 拿一个词去搜。
    ///
    /// - Returns: 候选（服务端顺序）。
    /// - Throws: `.notFound`（服务器明确说没有）/ `.unreachable`（超时 · 连不上 · 响应不成形）。
    func search(_ keyword: String) async throws -> [CoverCandidate]

    /// 把某个 URL 上的图取回来 —— 列表的缩略图、挑中的大图都走这儿。
    ///
    /// ⚠️ 请求头由**源自己**带：QQ 那台要 `Referer: https://y.qq.com/`，酷狗不要 ——
    /// 这个差别是源的私事，不该漏到调用方去。
    ///
    /// - Throws: `.unreachable`（连不上 / 非 2xx）。
    func imageData(from url: URL) async throws -> Data
}

// MARK: - 收尾

/// 封面这一摊的收尾 —— **只有两种**。
///
/// 🔴 「搜到了」不是错误，所以这里只有两态；而这两态**必须分开**
/// （同 `LyricsFetchError` 那条纪律）：把"连不上"当成"没搜到"，
/// 一断网就会让用户以为这首歌没封面。文案也必须不一样 ——
/// 用户得能分清"这首真没有"和"我这会儿上不了网"。
///
/// ⚠️ 源抛它、协调器归一也用它（值域相同）—— 不为"源级"另立一套同义词。
enum CoverSearchError: LocalizedError, Equatable {

    /// 服务器明确说没有（两个源都真答 0 条）。
    case notFound

    /// 超时 · 连不上 · `5xx` · 响应不成形。
    ///
    /// 🔴 语义上**不是**"这首歌没封面"的证据 —— 所以文案只说网络，不暗示"这首没图"。
    case unreachable

    /// 人话 —— **非可选那一版**，页面直接用（同 `LyricsFetchError.message`）。
    ///
    /// 页面里要是写成 `error.errorDescription ?? "获取失败"`，那个兜底字符串是**死代码**
    /// （这里永远给值），可它会让人以为"还有第三种没话说的收尾"。
    var message: String {
        switch self {
        case .notFound: return "没搜到，换个词试试"
        case .unreachable: return "连不上，检查网络"
        }
    }

    var errorDescription: String? { message }
}
