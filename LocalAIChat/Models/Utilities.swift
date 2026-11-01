import Foundation
import UIKit

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmed.isEmpty }
}

enum Format {
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// 00:12.5 / 1:02:03
    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let tenth = Int((seconds - Double(total)) * 10)
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d.%d", m, s, tenth)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// 拆分推理模型（DeepSeek-R1、QwQ、Qwen3 等）输出中的 <think>…</think>。
enum ThinkParser {
    static func split(_ content: String) -> (thinking: String, answer: String) {
        if let start = content.range(of: "<think>") {
            let before = String(content[..<start.lowerBound])
            let rest = content[start.upperBound...]
            if let end = rest.range(of: "</think>") {
                let thinking = String(rest[..<end.lowerBound])
                let answer = before + String(rest[end.upperBound...])
                return (thinking.trimmed, answer.trimmed)
            }
            // 还在思考中
            return (String(rest).trimmed, before.trimmed)
        }
        if let end = content.range(of: "</think>") {
            return (String(content[..<end.lowerBound]).trimmed, String(content[end.upperBound...]).trimmed)
        }
        return ("", content)
    }
}

/// 附件文件存储（与 UI / Actor 无关，可在后台线程使用）
enum Storage {
    static let baseDirectory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalAIChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let attachmentsDirectory: URL = {
        let url = baseDirectory.appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var dataFile: URL { baseDirectory.appendingPathComponent("data.json") }

    static func attachmentURL(_ fileName: String) -> URL {
        attachmentsDirectory.appendingPathComponent(fileName)
    }

    static func saveAttachment(_ data: Data) throws -> String {
        let name = UUID().uuidString + ".jpg"
        try data.write(to: attachmentURL(name), options: .atomic)
        return name
    }

    static func loadAttachment(_ fileName: String) -> Data? {
        try? Data(contentsOf: attachmentURL(fileName))
    }

    static func deleteAttachment(_ fileName: String) {
        try? FileManager.default.removeItem(at: attachmentURL(fileName))
        ImageCache.shared.remove(fileName)
    }

    /// 删除没有被任何消息引用的附件文件
    static func removeOrphans(keeping referenced: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: attachmentsDirectory.path) else { return }
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: attachmentURL(file))
        }
    }
}

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 200
    }

    func image(for fileName: String) -> UIImage? {
        if let cached = cache.object(forKey: fileName as NSString) {
            return cached
        }
        guard let image = UIImage(contentsOfFile: Storage.attachmentURL(fileName).path) else { return nil }
        cache.setObject(image, forKey: fileName as NSString)
        return image
    }

    func remove(_ fileName: String) {
        cache.removeObject(forKey: fileName as NSString)
    }
}
