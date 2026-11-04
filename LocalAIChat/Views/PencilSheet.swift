import PencilKit
import SwiftUI
import Vision

/// 要标注的图片（nil = 空白画板，用来手写或画草图）
struct AnnotationSource: Identifiable {
    let id = UUID()
    let image: UIImage?
}

/// Apple Pencil 画板：在图片上圈选 / 标注，或手写文字识别成提示词
struct PencilSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let background: UIImage?
    /// 附加图片，并给出建议的提示词
    let onAttach: ([Attachment], String) -> Void
    /// 识别出的文字放进输入框
    let onInsertText: (String) -> Void

    @State private var drawing = PKDrawing()
    @State private var toolPicker = PKToolPicker()
    @State private var canvasSize: CGSize = .zero
    @State private var fingerDrawing = UIDevice.current.userInterfaceIdiom != .pad
    @State private var includeCrop = true
    @State private var working: String?
    @State private var recognized: RecognizedText?
    @State private var errorMessage: String?

    private struct RecognizedText: Identifiable {
        let id = UUID()
        var text: String
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let size = fittedSize(in: geometry.size)
                ZStack {
                    if let background {
                        Image(uiImage: background)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                    } else {
                        Color.white
                            .frame(width: size.width, height: size.height)
                    }
                    PencilCanvas(
                        drawing: $drawing,
                        allowsFinger: fingerDrawing,
                        inkColor: background == nil ? .black : .systemRed,
                        toolPicker: toolPicker
                    )
                    .frame(width: size.width, height: size.height)
                }
                .shadow(color: .black.opacity(0.15), radius: 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { canvasSize = size }
                .onChange(of: geometry.size) { _, newSize in canvasSize = fittedSize(in: newSize) }
            }
            .background(Color(.systemGroupedBackground))
            .overlay(alignment: .top) {
                if let working {
                    Label(working, systemImage: "hourglass")
                        .font(.caption)
                        .padding(8)
                        .background(Capsule().fill(.regularMaterial))
                        .padding(.top, 8)
                } else if drawing.strokes.isEmpty {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Capsule().fill(.regularMaterial))
                        .padding(.top, 8)
                }
            }
            .navigationTitle(background == nil ? String(localized: "画板") : String(localized: "标注图片"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("撤销最后一笔", systemImage: "arrow.uturn.backward") {
                            if !drawing.strokes.isEmpty { drawing.strokes.removeLast() }
                        }
                        .disabled(drawing.strokes.isEmpty)
                        Button("清除全部", systemImage: "trash", role: .destructive) {
                            drawing = PKDrawing()
                        }
                        Toggle("用手指绘图", isOn: $fingerDrawing)
                        if background != nil {
                            Toggle("附上圈选区域放大图", isOn: $includeCrop)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button(background == nil ? String(localized: "作为图片发送") : String(localized: "附加标注后的图片"), systemImage: "photo.badge.plus") {
                            Task { await attachImage() }
                        }
                        Button("识别手写文字", systemImage: "text.viewfinder") {
                            Task { await recognizeHandwriting() }
                        }
                        .disabled(drawing.strokes.isEmpty)
                    } label: {
                        Text("完成").fontWeight(.semibold)
                    }
                    .disabled(working != nil || (background == nil && drawing.strokes.isEmpty))
                }
            }
            .sheet(item: $recognized) { item in
                RecognizedTextSheet(text: item.text) { text in
                    onInsertText(text)
                    dismiss()
                } onAskModel: {
                    Task { await attachImage(prompt: String(localized: "图中是我手写的内容，请先识别出文字，再按照其中的要求回答。")) }
                }
            }
            .alert("提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var hint: String {
        if background != nil {
            return fingerDrawing ? String(localized: "用笔或手指圈出想问的地方") : String(localized: "用 Apple Pencil 圈出想问的地方")
        }
        return String(localized: "在这里手写问题，或画一张草图")
    }

    /// 背景图片按比例放进可用区域；空白画板占满
    private func fittedSize(in available: CGSize) -> CGSize {
        let area = CGSize(width: max(available.width - 32, 100), height: max(available.height - 32, 100))
        guard let background, background.size.width > 0, background.size.height > 0 else { return area }
        let scale = min(area.width / background.size.width, area.height / background.size.height)
        return CGSize(width: background.size.width * scale, height: background.size.height * scale)
    }

    // MARK: - 导出

    /// 背景 + 笔迹合成的完整图片，以及圈选区域的放大图
    private func renderImages() -> (full: UIImage, crop: UIImage?)? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let outputSize = background?.size ?? CGSize(width: canvasSize.width * 2, height: canvasSize.height * 2)
        let scale = outputSize.width / canvasSize.width

        // 深色模式下 PencilKit 会反转颜色，导出时固定使用浅色外观
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: scale)
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rect = CGRect(origin: .zero, size: outputSize)
        let full = UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(rect)
            background?.draw(in: rect)
            ink.draw(in: rect)
        }

        var crop: UIImage?
        let bounds = drawing.bounds
        if background != nil, includeCrop, !bounds.isEmpty {
            let padded = bounds.insetBy(dx: -24, dy: -24).intersection(CGRect(origin: .zero, size: canvasSize))
            let pixelRect = CGRect(
                x: padded.minX * scale,
                y: padded.minY * scale,
                width: padded.width * scale,
                height: padded.height * scale
            ).integral
            // 圈选范围太小或几乎是整张图时不另外附上
            let coverage = (pixelRect.width * pixelRect.height) / (outputSize.width * outputSize.height)
            if pixelRect.width > 48, pixelRect.height > 48, coverage < 0.8,
               let cgImage = full.cgImage?.cropping(to: pixelRect) {
                crop = UIImage(cgImage: cgImage)
            }
        }
        return (full, crop)
    }

    /// 只有笔迹（白底），用于文字识别
    private func renderInkOnly() -> UIImage? {
        let bounds = drawing.bounds.insetBy(dx: -20, dy: -20)
        guard !bounds.isEmpty else { return nil }
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: bounds, scale: 2)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: bounds.size))
            ink.draw(in: CGRect(origin: .zero, size: bounds.size))
        }
    }

    private func attachImage(prompt: String? = nil) async {
        guard let images = renderImages() else { return }
        working = String(localized: "正在处理图片…")
        defer { working = nil }

        var attachments: [Attachment] = []
        for image in [images.full, images.crop].compactMap({ $0 }) {
            guard let data = image.jpegData(compressionQuality: 0.92),
                  let attachment = await AttachmentFactory.image(from: data, settings: store.media) else { continue }
            attachments.append(attachment)
        }
        guard !attachments.isEmpty else {
            errorMessage = String(localized: "无法生成图片。")
            return
        }

        let suggestion: String
        if let prompt {
            suggestion = prompt
        } else if background == nil {
            suggestion = String(localized: "这是我手写 / 画的内容，请先识别，再回答其中的问题。")
        } else if drawing.strokes.isEmpty {
            suggestion = ""
        } else if attachments.count > 1 {
            suggestion = String(localized: "请重点看图中用笔圈出或标注的部分（第二张图是圈选区域的放大图）。")
        } else {
            suggestion = String(localized: "请重点看图中用笔圈出或标注的部分。")
        }
        onAttach(attachments, suggestion)
        dismiss()
    }

    private func recognizeHandwriting() async {
        guard let image = renderInkOnly(), let cgImage = image.cgImage else { return }
        working = String(localized: "正在识别手写文字…")
        let text = await Task.detached(priority: .userInitiated) { Self.recognizeText(in: cgImage) }.value
        working = nil
        recognized = RecognizedText(text: text)
    }

    /// 苹果 Vision 文字识别（在本机完成），支持中文和英文
    nonisolated static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let observations = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

/// 识别结果：可以修改后放进输入框；识别不准时改为让模型直接看手写图片
private struct RecognizedTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    let onInsert: (String) -> Void
    let onAskModel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if text.isBlank {
                        Text("没有识别出文字。可以写得再清楚一些，或者让 AI 直接看手写内容。")
                            .foregroundStyle(.secondary)
                    }
                    TextField("识别结果", text: $text, axis: .vertical)
                        .lineLimit(3...12)
                } header: {
                    Text("识别结果（可以修改）")
                } footer: {
                    Text("文字识别在本机完成。中文手写识别不一定准确，也可以选择「让 AI 识别手写图片」。")
                }
                Section {
                    Button("让 AI 识别手写图片", systemImage: "photo") {
                        dismiss()
                        onAskModel()
                    }
                }
            }
            .navigationTitle("手写文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("放入输入框") {
                        onInsert(text.trimmed)
                    }
                    .disabled(text.isBlank)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// PencilKit 画布
struct PencilCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var allowsFinger: Bool
    var inkColor: UIColor
    let toolPicker: PKToolPicker

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawing = drawing
        canvas.drawingPolicy = allowsFinger ? .anyInput : .pencilOnly
        canvas.tool = PKInkingTool(.pen, color: inkColor, width: 5)
        canvas.delegate = context.coordinator
        toolPicker.addObserver(canvas)
        DispatchQueue.main.async {
            toolPicker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.drawingPolicy = allowsFinger ? .anyInput : .pencilOnly
        if canvas.drawing != drawing {
            canvas.drawing = drawing
        }
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        canvas.resignFirstResponder()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var drawing: Binding<PKDrawing>

        init(drawing: Binding<PKDrawing>) {
            self.drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if drawing.wrappedValue != canvasView.drawing {
                drawing.wrappedValue = canvasView.drawing
            }
        }
    }
}
