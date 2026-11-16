import Foundation

/// 一份歌词文本用的是**哪一种写法**（语法）。
///
/// 这是"写法"的名字，**不是能力**：能不能扫光、能不能逐字编辑，看模型里有没有字级数据
/// （`LyricsLine.hasKaraoke`），不看这个值（`歌词子系统设计.md` §3.1）。
///
/// ## 名字怎么来的
///
/// 一律用**通行格式名**（同文档 §3.1.1）：业界怎么叫就怎么叫，不用家族统称
/// （"A2"、"逐字歌词"那种说不清的），也不用"来源 ＋ 猜测"。
///
/// ## 🔴 行级与字级是**同一个** `.lrc`
///
/// `[mm:ss]整句` 与 `[mm:ss.mmm]<mm:ss.mmm>字…` 是同一套写法的两种容量：行内多写一层
/// 字标记就是字级，不写就是行级 —— **同一个字符串**，不许拆成两种格式。
///
/// ## 谁来回答"我是哪种"
///
/// 各解析器自己（`LyricsTextParser.syntax`），链上没有任何一处公共函数去猜。
/// 这个类型只负责"名字"和"能不能写回"，判断在解析器手里、写口在 `LyricsTextSerializer` 手里。
///
/// ```
/// 名字           读   写回原文   说明
/// lrc            ✅   ✅        行级／字级 LRC（ELRC 是它的字级容量）
/// krcLayout      ✅   ✅        `[起,长]<相对,长,flag>字`（酷狗解密后的明文）
/// yrc / qrc/lys  ✅   ❌        毫秒圆括号字块（同族一个解析器，靠参数分）
/// vtt / srt      ✅   ❌        字幕
/// ttml           ✅   ❌        只读版（译文/注音/和声一律丢）
/// ```
///
/// ⚠️ 上面"写回原文"说的是**编辑页**能不能把用户这份原文写回（§3.5）；取词出口不按这张表选，
/// 取回哪种都一律转 `.lrc`（§5.2）。
enum LyricsSyntax: String, CaseIterable {

    /// 行级／字级 LRC。行内没有 `<mm:ss.mmm>` 字标记就是行级，有就是字级。
    case lrc

    /// 酷狗 KRC 解密后的明文布局：`[行起,行长]<字相对起,字长,flag>字…`。
    ///
    /// `Layout` 这个词把"解密后的**文本布局**"与"二进制 `.krc` 文件"分清楚 ——
    /// 后者还得先解密（`Data/Lyrics/` 那一套），不归解析链管。
    case krcLayout

    /// NetEase 逐字歌词：`[行起,行长](字起,字长,0)字…`（圆括号、字块在字**前面**）。
    case yrc

    /// QQ 音乐逐字歌词：`[行起,行长]字(字起,字长)…`（圆括号、字块在字**后面**）。
    case qrc

    /// Lyricify 逐字歌词：`[属性数字]字(字起,字长)…`。
    case lys

    /// WebVTT 字幕。
    case vtt

    /// SubRip 字幕。
    case srt

    /// Apple Music 那套 TTML（只读版）。
    case ttml

    /// 编辑页能不能把用户这份原文**原样写回**。
    ///
    /// 🔴 这不是"我们支不支持这种格式"，而是"有没有一个不会丢东西的写口"：
    /// - `.lrc`：写口是 `LyricsTextSerializer.serializeLRC`（行级／字级同一套）；
    /// - `.krcLayout`：写口是 `serializeKRCLayout`（编辑页历史，用户已定「保存这条不变」）；
    /// - 其余（`yrc` / `qrc` / `lys` / `vtt` / `srt` / `ttml`）：**能看不能写** ——
    ///   它们进编辑页只读，保存时把原文原样写回，不会被改写成另一种语法（§6.3）。
    var hasWriter: Bool {
        switch self {
        case .lrc, .krcLayout:
            return true
        case .yrc, .qrc, .lys, .vtt, .srt, .ttml:
            return false
        }
    }

    /// 提示语里的名字（"TTML 歌词只能看，不能改"）。
    ///
    /// 用通行格式名，与 `hasWriter` 那张表对齐 —— 别在界面里各写一套。
    var displayName: String {
        switch self {
        case .lrc: return "LRC"
        case .krcLayout: return "KRC"
        case .yrc: return "YRC"
        case .qrc: return "QRC"
        case .lys: return "LYS"
        case .vtt: return "WebVTT"
        case .srt: return "SRT"
        case .ttml: return "TTML"
        }
    }
}
