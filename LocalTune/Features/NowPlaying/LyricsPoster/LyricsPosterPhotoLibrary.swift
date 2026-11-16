import Foundation
import Photos

/// 存相册时可能出的岔子。每种都带一句给人看的话。
enum LyricsPosterPhotoLibraryError: LocalizedError {
    /// 用户没给"仅添加"权限。
    case denied
    /// 系统写盘失败。
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .denied:
            return "需要相册权限才能存图，请到「设置」里打开"
        case .saveFailed(let message):
            return message.isEmpty ? "存到相册失败，请再试一次" : message
        }
    }
}

/// 把导出的海报存进系统相册。
///
/// 只申请**仅添加**权限 —— 分享歌词不需要读用户的照片，多要的那份权限是白拿的。
enum LyricsPosterPhotoLibrary {

    /// 存一张图。权限不够就报 `.denied`，不静默失败。
    static func save(image url: URL) async throws {
        guard await requestAddPermission() else {
            throw LyricsPosterPhotoLibraryError.denied
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset()
                    .addResource(with: .photo, fileURL: url, options: nil)
            }
        } catch {
            throw LyricsPosterPhotoLibraryError.saveFailed(error.localizedDescription)
        }
    }

    /// 存一张实况照片。
    ///
    /// 🔴 静图与视频必须写在**同一次** `performChanges` 里 —— 分两次提交会变成
    /// 一张普通照片外加一段视频，实况照片的配对关系就没了。
    static func save(livePhoto bundle: LyricsPosterLivePhotoBundle) async throws {
        guard await requestAddPermission() else {
            throw LyricsPosterPhotoLibraryError.denied
        }
        let stillURL = bundle.stillURL
        let videoURL = bundle.videoURL
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: stillURL, options: options)
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: options)
            }
        } catch {
            throw LyricsPosterPhotoLibraryError.saveFailed(error.localizedDescription)
        }
    }

    /// 要"仅添加"权限。已经给过就直接过；从没问过才弹系统询问。
    ///
    /// ⚠️ 这里**不判 `.limited`**：那是"选中部分照片"那一档，按 Apple 的说法只对
    /// `.readWrite` 生效，`.addOnly` 只可能给 `.authorized` / `.denied` / `.restricted`。
    private static func requestAddPermission() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized:
            return true
        case .notDetermined:
            return await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
        default:
            return false
        }
    }
}
