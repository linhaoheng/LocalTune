import Foundation

/// 库 / 系统的 `Error` → 三种 `PlaybackError`。
///
/// 🔴 **不 import SFB**：判断层不许碰引擎。域字符串对着库源码写死
/// （`SFBAudioPlayer.mm` / `SFBAudioDecoder.m` / `SFBInputSource.m`）。
/// 认不出的一律 `.engineFailed`（偏安全：停，不瞎跳）。
func playbackError(from error: Error) -> PlaybackError {
    let ns = error as NSError

    if isMissingFile(ns) { return .fileMissing }
    if isUnsupportedFormat(ns) { return .unsupportedFormat }
    return .engineFailed
}

// MARK: - 私有

private func isMissingFile(_ error: NSError) -> Bool {
    // InputSource.ErrorCodeFileNotFound = 0
    if error.domain == "org.sbooth.AudioEngine.InputSource", error.code == 0 {
        return true
    }
    if error.domain == NSCocoaErrorDomain {
        switch error.code {
        case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
            return true
        default:
            break
        }
    }
    // InputSource 打开失败常见包一层 Cocoa；底层也可能是 POSIX ENOENT。
    if error.domain == NSPOSIXErrorDomain, error.code == ENOENT {
        return true
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        return isMissingFile(underlying)
    }
    return false
}

private func isUnsupportedFormat(_ error: NSError) -> Bool {
    // AudioPlayer.ErrorCodeFormatNotSupported = 1
    if error.domain == "org.sbooth.AudioEngine.AudioPlayer", error.code == 1 {
        return true
    }
    // AudioDecoder：InvalidFormat=1 · UnsupportedFormat=2
    if error.domain == "org.sbooth.AudioEngine.AudioDecoder", (1...2).contains(error.code) {
        return true
    }
    // DSDDecoder 同码
    if error.domain == "org.sbooth.AudioEngine.DSDDecoder", (1...2).contains(error.code) {
        return true
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        return isUnsupportedFormat(underlying)
    }
    return false
}
