import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ProcessedImage {
    let data: Data
    let width: Int
    let height: Int
    let originalByteCount: Int
}

/// 图片压缩：使用 ImageIO 直接下采样（省内存、支持 HEIC、自动处理方向），再编码为 JPEG。
enum ImageProcessor {

    /// - Parameters:
    ///   - maxDimension: 最长边像素，0 = 不缩放
    ///   - quality: JPEG 质量 0...1
    ///   - maxKB: 体积上限（KB），0 = 不限。超出时先逐步降低质量，再逐步缩小尺寸。
    static func compress(data: Data, maxDimension: Int, quality: Double, maxKB: Int) -> ProcessedImage? {
        guard let image = downsample(data: data, maxDimension: maxDimension) else { return nil }
        return compress(cgImage: image, quality: quality, maxKB: maxKB, originalByteCount: data.count)
    }

    static func compress(cgImage: CGImage, quality: Double, maxKB: Int = 0, originalByteCount: Int = 0) -> ProcessedImage? {
        var image = flattenIfNeeded(cgImage)
        var q = min(max(quality, 0.05), 1.0)
        guard var output = encodeJPEG(image, quality: q) else { return nil }

        if maxKB > 0 {
            let limit = maxKB * 1024
            var attempts = 0
            while output.count > limit && attempts < 12 {
                attempts += 1
                if q > 0.4 {
                    q -= 0.1
                } else if let smaller = resize(image, scale: 0.8) {
                    image = smaller
                } else {
                    break
                }
                guard let next = encodeJPEG(image, quality: q) else { break }
                output = next
            }
        }

        return ProcessedImage(
            data: output,
            width: image.width,
            height: image.height,
            originalByteCount: originalByteCount > 0 ? originalByteCount : output.count
        )
    }

    static func downsample(data: Data, maxDimension: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }

        var maxPixel = maxDimension
        if maxPixel <= 0 {
            // 不缩放：取原图最长边
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int,
               let h = props[kCGImagePropertyPixelHeight] as? Int {
                maxPixel = max(w, h)
            } else {
                maxPixel = 4096
            }
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 等比缩放
    static func resize(_ image: CGImage, scale: Double) -> CGImage? {
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard width >= 64, height >= 64 else { return nil }
        return draw(image, width: width, height: height)
    }

    /// JPEG 不支持透明，透明区域铺白底，避免变成黑色
    private static func flattenIfNeeded(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            return draw(image, width: image.width, height: image.height) ?? image
        }
    }

    private static func draw(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
