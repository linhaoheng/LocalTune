import AppIntents
import Foundation

/// Siri / 快捷指令「播什么」这件事的**词汇表** —— 属**系统入口**那一族，归 App 层。
///
/// 🔴 **为什么归 `App/Intents/`（而不是 `Playback/Model/`）**：宪法 §一 把「**系统入口（Siri / 快捷指令）**」
/// 划给 **App 层**；§三·判断归位 1 的判据是「输入 / 输出得是**播放域自己的值**」—— 本文件全是 **Siri 的词汇**
/// （`MediaPlay*` / `Shortcut*`），属**入口翻译**，归**拥有那条入口的层**。消费者（`PlayMediaIntentHandling` ·
/// `LocalTuneIntentBridge` · `AppServices`）**也都在 App 层**（`Playback/` 里一个消费者都没有）。
///
/// `INPlayMediaIntent` → `MediaPlayRequest` 的映射留在同目录 `PlayMediaIntentHandling.swift`；
/// 两个判断（`MediaPlayTargetPolicy` · `ShortcutPlaybackModePolicy`）与它**同层同目录**。

enum MediaPlayRequest: Equatable {
    enum ItemKind: Equatable {
        case song
        case playlist
        case album
        case other
    }

    /// Siri 已给出媒体条目。
    case mediaItem(kind: ItemKind, identifier: String, title: String)
    /// 只有搜索字段。
    case search(kind: ItemKind, name: String)
    /// 条目和搜索都空 —— 「用 LocalTune 播放音乐」这类。
    case bare
}

enum MediaPlayFailure: Equatable {
    case emptyLibrary
    case emptyPlaylist
    case missingPlaylist
    case notFound
}

enum MediaPlayTarget: Equatable {
    /// 用这些 id 组队列并从头曲起播。
    case play(trackIDs: [String], startID: String)
    /// 已有当前曲：确保在播，不重开队列。
    case ensurePlayingCurrent
    case failure(MediaPlayFailure)
}

struct MediaPlayLibrary: Equatable {
    struct Track: Equatable {
        let id: String
        let title: String
        let album: String
    }

    struct Playlist: Equatable {
        let id: UUID
        let name: String
        let trackIDs: [String]
    }

    let tracks: [Track]
    let playlists: [Playlist]
}

struct MediaPlaySession: Equatable {
    let currentTrackID: String?
    let isPlaybackActive: Bool
}

/// 快捷指令那两个参数（随机 / 重复）在**我们这边**的词汇 —— `PlaySongsIntent` 用它收参数，
/// 判断（`ShortcutPlaybackModePolicy`，同目录）用它落回 `PlaybackMode`。
///
/// 🔴 **为什么归 `Model/`**：它**判断和入口两边都用**。
///
/// 🔴 **为什么 `AppEnum` 遵循也必须写在这个文件（不能在 `Intents/` 再 `extension`）**：
/// 1. `AppEnum` 继承 `CaseIterable`，而 `allCases` **只在和类型同一个文件里**才自动合成 ——
///    拆到别的文件直接**编不过**。
/// 2. 宪法 §三·规模 4：**协议实现单独拆一个文件就是「假拆」**（`extension` 假分层）。
/// ⇒ 声明和遵循只能同处一个文件；这个文件既然是它的家，遵循就落在这儿。
///   （`Model/` 引系统框架不是头一回：`AudioSessionTypes.swift` 就 `import AVFAudio`。）
enum ShortcutShuffleMode: String, AppEnum {
    case off
    case songs

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "随机播放")
    static let caseDisplayRepresentations: [ShortcutShuffleMode: DisplayRepresentation] = [
        .off: "关闭",
        .songs: "歌曲"
    ]
}

enum ShortcutRepeatMode: String, AppEnum {
    case off
    case one
    case all

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "重复")
    static let caseDisplayRepresentations: [ShortcutRepeatMode: DisplayRepresentation] = [
        .off: "关闭",
        .one: "单曲",
        .all: "全部"
    ]
}
