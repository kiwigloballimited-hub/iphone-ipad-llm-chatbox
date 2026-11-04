import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// 导入 PDF / 文本文件：提取文字作为上下文；扫描版 PDF 转成图片
enum DocumentImporter {
    /// 每个文档最多保存的字符数
    static let maxStoredCharacters = 300_000
    /// 扫描版 PDF 最多转换的页数
    static let maxScannedPages = 6

    struct Imported {
        var attachments: [Attachment] = []
        var note: String?
    }

    static func isDocument(_ type: UTType) -> Bool {
        type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .json)
            || type.conforms(to: .xml) || type.conforms(to: .commaSeparatedText)
    }

    /// 支持的文件类型（用于「从文件选择」和拖拽）
    static let supportedTypes: [UTType] = [.pdf, .text, .json, .xml, .commaSeparatedText]

    static func importFile(at url: URL, type: UTType, settings: MediaSettings) async -> Imported {
        let name = url.lastPathComponent
        if type.conforms(to: .pdf) {
            return await importPDF(at: url, name: name, settings: settings)
        }
        let text = await Task.detached(priority: .userInitiated) { readText(at: url, type: type) }.value
        guard let text, !text.isBlank else {
            return Imported(note: String(localized: "「\(name)」里没有可以读取的文字。"))
        }
        guard let attachment = await AttachmentFactory.document(name: name, text: text, pageCount: nil, originalByteCount: AttachmentFactory.fileSize(url)) else {
            return Imported(note: String(localized: "无法保存「\(name)」。"))
        }
        return Imported(attachments: [attachment])
    }

    /// 拖进来或粘贴的一大段文字，作为文档附件
    static func importText(_ text: String, name: String) async -> Attachment? {
        await AttachmentFactory.document(name: name, text: text, pageCount: nil, originalByteCount: text.utf8.count)
    }

    private static func importPDF(at url: URL, name: String, settings: MediaSettings) async -> Imported {
        let result = await Task.detached(priority: .userInitiated) { () -> (text: String, pages: Int, images: [Data])? in
            guard let document = PDFDocument(url: url) else { return nil }
            let pages = document.pageCount
            let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // 平均每页文字很少：多半是扫描件，转成图片让视觉模型读
            var images: [Data] = []
            if text.count < max(40, pages * 30) {
                for index in 0..<min(pages, maxScannedPages) {
                    guard let page = document.page(at: index) else { continue }
                    let image = page.thumbnail(of: CGSize(width: 1600, height: 1600), for: .mediaBox)
                    if let data = image.jpegData(compressionQuality: 0.85) { images.append(data) }
                }
            }
            return (text, pages, images)
        }.value

        guard let result else { return Imported(note: String(localized: "无法打开「\(name)」，文件可能已加密或损坏。")) }

        var imported = Imported()
        if !result.text.isEmpty,
           let attachment = await AttachmentFactory.document(name: name, text: result.text, pageCount: result.pages, originalByteCount: AttachmentFactory.fileSize(url)) {
            imported.attachments.append(attachment)
        }
        for data in result.images {
            if let image = await AttachmentFactory.image(from: data, settings: settings) {
                imported.attachments.append(image)
            }
        }
        if !result.images.isEmpty {
            let more = result.pages > maxScannedPages ? String(localized: "（只转换了前 \(maxScannedPages) 页）") : ""
            imported.note = String(localized: "「\(name)」看起来是扫描件，已把页面转成图片\(more)。识别图片需要视觉模型。")
        }
        if imported.attachments.isEmpty {
            imported.note = String(localized: "「\(name)」里没有可以读取的内容。")
        }
        return imported
    }

    private static func readText(at url: URL, type: UTType) -> String? {
        if type.conforms(to: .rtf) || type.conforms(to: .flatRTFD) {
            let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil)
            return attributed?.string
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// 依次尝试 UTF-8、UTF-16、GB18030（常见的中文编码）
    static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb18030) { return text }
        return String(data: data, encoding: .isoLatin1)
    }
}
