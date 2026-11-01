import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// 从相册导入视频时，先复制到临时目录
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return MovieFile(url: destination)
        }
    }
}

/// 把图片 / 视频帧压缩后保存为附件（在后台线程执行）
enum AttachmentFactory {
    static func image(from data: Data, settings: MediaSettings) async -> Attachment? {
        await Task.detached(priority: .userInitiated) { () -> Attachment? in
            guard let processed = ImageProcessor.compress(
                data: data,
                maxDimension: settings.imageMaxDimension,
                quality: settings.imageQuality,
                maxKB: settings.imageMaxKB
            ) else { return nil }
            guard let fileName = try? Storage.saveAttachment(processed.data) else { return nil }
            return Attachment(
                kind: .image,
                fileName: fileName,
                width: processed.width,
                height: processed.height,
                byteCount: processed.data.count,
                originalByteCount: data.count
            )
        }.value
    }

    static func videoFrames(_ frames: [ExtractedFrame], duration: Double, originalByteCount: Int) async -> [Attachment] {
        await Task.detached(priority: .userInitiated) { () -> [Attachment] in
            let groupID = UUID()
            let perFrameOriginal = frames.isEmpty ? 0 : originalByteCount / frames.count
            return frames.sorted { $0.time < $1.time }.compactMap { frame in
                guard let fileName = try? Storage.saveAttachment(frame.image.data) else { return nil }
                return Attachment(
                    kind: .videoFrame,
                    fileName: fileName,
                    width: frame.image.width,
                    height: frame.image.height,
                    byteCount: frame.image.data.count,
                    originalByteCount: perFrameOriginal,
                    timestamp: frame.time,
                    videoGroupID: groupID,
                    videoDuration: duration
                )
            }
        }.value
    }

    static func isVideo(_ type: UTType) -> Bool {
        type.conforms(to: .movie) || type.conforms(to: .video)
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
