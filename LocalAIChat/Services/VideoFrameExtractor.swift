import AVFoundation
import CoreGraphics
import Foundation
import UIKit

struct ExtractedFrame: Identifiable {
    let id = UUID()
    /// 实际抽到的时间点（秒）
    let time: Double
    let image: ProcessedImage
    let thumbnail: UIImage?
}

struct VideoExtractionResult {
    let frames: [ExtractedFrame]
    let duration: Double
    let naturalSize: CGSize
}

enum VideoError: LocalizedError {
    case noVideoTrack
    case noFrames

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return String(localized: "这个文件里没有视频轨道。")
        case .noFrames: return String(localized: "未能从视频中抽取到任何画面。")
        }
    }
}

/// 视频解码抽帧：使用 AVAssetImageGenerator 按时间点解码画面，再压缩为 JPEG。
enum VideoFrameExtractor {

    /// 计算抽帧时间点
    static func sampleTimes(duration: Double, settings: MediaSettings) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [0] }
        switch settings.videoFrameMode {
        case .uniform:
            let count = max(1, settings.videoFrameCount)
            // 取每一段的中点，避开片头黑屏和片尾
            return (0..<count).map { (Double($0) + 0.5) * duration / Double(count) }
        case .interval:
            let step = max(0.2, settings.videoFrameInterval)
            let limit = max(1, settings.videoMaxFrames)
            var times: [Double] = []
            var t = min(0.1, duration / 2)
            while t < duration && times.count < limit {
                times.append(t)
                t += step
            }
            return times.isEmpty ? [0] : times
        }
    }

    static func extract(
        from url: URL,
        settings: MediaSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> VideoExtractionResult {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw VideoError.noVideoTrack }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displaySize = naturalSize.applying(transform)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if settings.videoFrameMaxDimension > 0 {
            let d = CGFloat(settings.videoFrameMaxDimension)
            generator.maximumSize = CGSize(width: d, height: d)
        }
        // 适当的容差可以显著加快解码（会吸附到附近的关键帧）
        let tolerance = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let times = sampleTimes(duration: duration, settings: settings)
        var frames: [ExtractedFrame] = []

        for (index, time) in times.enumerated() {
            try Task.checkCancellation()
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            do {
                let (cgImage, actualTime) = try await generator.image(at: cmTime)
                if let processed = ImageProcessor.compress(cgImage: cgImage, quality: settings.videoFrameQuality) {
                    let thumb = UIImage(data: processed.data)
                    let actual = actualTime.seconds.isFinite ? actualTime.seconds : time
                    frames.append(ExtractedFrame(time: actual, image: processed, thumbnail: thumb))
                }
            } catch {
                if error is CancellationError { throw error }
                // 个别时间点解码失败时跳过
            }
            progress(Double(index + 1) / Double(times.count))
        }

        guard !frames.isEmpty else { throw VideoError.noFrames }
        return VideoExtractionResult(
            frames: frames,
            duration: duration,
            naturalSize: CGSize(width: abs(displaySize.width), height: abs(displaySize.height))
        )
    }
}
