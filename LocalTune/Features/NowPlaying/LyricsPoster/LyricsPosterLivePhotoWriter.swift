import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 一张实况照片的两半。
///
/// 系统靠写在两个文件里的**同一个 asset identifier** 把它们配成一张实况照片 ——
/// 少了任何一半，存进相册就只会变成普通照片、或一段普通视频。
struct LyricsPosterLivePhotoBundle {
    let stillURL: URL
    let videoURL: URL
    let assetIdentifier: String
}

/// 逐帧写实况照片时可能出的岔子。每种都带一句给人看的话。
enum LyricsPosterLivePhotoError: LocalizedError {
    /// 某一帧渲染不出像素。
    case renderFailed
    /// 视频轨搭不起来（编码参数、像素缓冲池）。
    case videoSetupFailed
    /// 视频写盘失败，带上系统那句话。
    case videoWriteFailed(String)
    /// 静图那张 JPEG 写不出来。
    case stillWriteFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed:
            return "海报生成失败，请换一种风格再试"
        case .videoSetupFailed:
            return "动态海报导出失败，请再试一次"
        case .videoWriteFailed(let message):
            return message.isEmpty ? "动态海报导出失败，请再试一次" : "动态海报导出失败：\(message)"
        case .stillWriteFailed:
            return "海报写文件失败，请再试一次"
        }
    }
}

/// 逐帧把海报写成实况照片。
///
/// ## 帧是"拉"过来的
///
/// 一段 1080×1920 的五秒动画有一百多帧，全留在内存里是几百 MB，手机上必然被系统
/// 杀掉。所以这里不接"一帧数组"，只接一个**按需渲染第 N 帧**的闭包。
///
/// 静图那一帧**先渲染**：它是相册里静止时显示的那张，也是导出中途失败时唯一还能
/// 交付给用户的东西。
@MainActor
enum LyricsPosterLivePhotoWriter {

    /// 静图那一帧在视频里的停留窗口。太短系统会认不出静帧标记。
    private static let stillImageTimeWindow = CMTime(value: 1, timescale: 10)

    static func write(
        plan: LyricsPosterMotionPlan,
        size: CGSize,
        directory: URL,
        baseName: String,
        frame: @MainActor (Int) -> CGImage?,
        onProgress: @MainActor (Double) -> Void = { _ in }
    ) async throws -> LyricsPosterLivePhotoBundle {
        let assetIdentifier = UUID().uuidString
        let videoURL = directory.appendingPathComponent("\(baseName).mov")
        let stillURL = directory.appendingPathComponent("\(baseName).jpg")
        // 敢吞：删不掉重名的旧临时文件不挡这次写入；真写不进去下面会自己报出来。
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: stillURL)

        guard let stillImage = frame(plan.stillFrameIndex) else {
            throw LyricsPosterLivePhotoError.renderFailed
        }
        try writeStill(stillImage, assetIdentifier: assetIdentifier, to: stillURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        } catch {
            throw LyricsPosterLivePhotoError.videoWriteFailed(error.localizedDescription)
        }
        writer.metadata = [contentIdentifierItem(assetIdentifier)]

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(size.width * size.height * 6),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
        )
        videoInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )

        guard let stillTimeDescription = makeStillImageTimeFormatDescription() else {
            throw LyricsPosterLivePhotoError.videoSetupFailed
        }
        let metadataInput = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: stillTimeDescription
        )
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

        guard writer.canAdd(videoInput), writer.canAdd(metadataInput) else {
            throw LyricsPosterLivePhotoError.videoSetupFailed
        }
        writer.add(videoInput)
        writer.add(metadataInput)

        guard writer.startWriting() else {
            throw LyricsPosterLivePhotoError.videoWriteFailed(writer.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)

        // 静帧标记必须指向视频里的某个时刻，否则系统只当它是一段普通视频。
        let stillTime = CMTime(
            value: CMTimeValue(plan.stillFrameIndex),
            timescale: CMTimeScale(plan.frameRate)
        )
        _ = metadataAdaptor.append(
            AVTimedMetadataGroup(
                items: [stillImageTimeItem()],
                timeRange: CMTimeRange(start: stillTime, duration: stillImageTimeWindow)
            )
        )
        metadataInput.markAsFinished()

        let frameCount = plan.frameCount
        for index in 0..<frameCount {
            if Task.isCancelled {
                writer.cancelWriting()
                throw CancellationError()
            }
            guard let image = frame(index) else {
                writer.cancelWriting()
                throw LyricsPosterLivePhotoError.renderFailed
            }
            // 编码器还没吃下上一帧就让出主线程 —— 渲染在主线程上跑，死等会让进度条
            // 和取消键整段时间都是死的。
            while !videoInput.isReadyForMoreMediaData {
                // 敢吞：只是让出几毫秒等编码器；真写不进去，下面的 append 会失败并报出来。
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
            guard let buffer = makePixelBuffer(from: image, pool: adaptor.pixelBufferPool, size: size) else {
                writer.cancelWriting()
                throw LyricsPosterLivePhotoError.videoSetupFailed
            }
            let presentationTime = CMTime(
                value: CMTimeValue(index),
                timescale: CMTimeScale(plan.frameRate)
            )
            guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                writer.cancelWriting()
                throw LyricsPosterLivePhotoError.videoWriteFailed(writer.error?.localizedDescription ?? "")
            }
            onProgress(Double(index + 1) / Double(frameCount))
            // 渲染在主线程上跑，不让出的话进度条和取消按钮整段时间都是死的。
            await Task.yield()
        }

        videoInput.markAsFinished()
        await finishWriting(writer)

        guard writer.status == .completed else {
            throw LyricsPosterLivePhotoError.videoWriteFailed(writer.error?.localizedDescription ?? "")
        }

        return LyricsPosterLivePhotoBundle(
            stillURL: stillURL,
            videoURL: videoURL,
            assetIdentifier: assetIdentifier
        )
    }

    // MARK: - 文件写出

    /// 静图必须带上 Apple 私有 maker note 的 17 号键 —— 那就是实况照片的配对标识，
    /// 写成普通 JPEG 会把它丢掉。
    static func writeStill(
        _ image: CGImage,
        assetIdentifier: String,
        to url: URL
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw LyricsPosterLivePhotoError.stillWriteFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.96,
            kCGImagePropertyMakerAppleDictionary: ["17": assetIdentifier],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LyricsPosterLivePhotoError.stillWriteFailed
        }
    }

    private static func contentIdentifierItem(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = AVMetadataKey.quickTimeMetadataKeyContentIdentifier as NSString
        item.keySpace = .quickTimeMetadata
        item.value = identifier as NSString
        return item
    }

    private static func stillImageTimeItem() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.still-image-time" as NSString
        item.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        item.value = 0 as NSNumber
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        return item
    }

    private static func makeStillImageTimeFormatDescription() -> CMFormatDescription? {
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_SInt8 as String,
        ]
        var description: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    private static func makePixelBuffer(
        from image: CGImage,
        pool: CVPixelBufferPool?,
        size: CGSize
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        } else {
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(size.width),
                Int(size.height),
                kCVPixelFormatType_32BGRA,
                [
                    kCVPixelBufferCGImageCompatibilityKey: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                ] as CFDictionary,
                &buffer
            )
        }
        guard let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        )
        return pixelBuffer
    }

    /// 等 `finishWriting` 回调，把它包成异步 —— 写盘的那几秒不该卡着主线程。
    private static func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }
}
