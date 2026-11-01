import SwiftUI

/// 视频抽帧界面：调整抽帧参数、预览画面、勾选要发送的帧
struct VideoFramePickerView: View {
    @Environment(\.dismiss) private var dismiss

    let session: VideoSession
    let onConfirm: ([ExtractedFrame], Double) -> Void

    @State private var settings: MediaSettings
    @State private var frames: [ExtractedFrame] = []
    @State private var selected: Set<UUID> = []
    @State private var duration: Double = 0
    @State private var videoSize: CGSize = .zero
    @State private var progress: Double = 0
    @State private var isExtracting = false
    @State private var errorText: String?
    @State private var extractionTask: Task<Void, Never>?
    @State private var previewFrame: ExtractedFrame?

    init(session: VideoSession, initialSettings: MediaSettings, onConfirm: @escaping ([ExtractedFrame], Double) -> Void) {
        self.session = session
        self.onConfirm = onConfirm
        _settings = State(initialValue: initialSettings)
    }

    var body: some View {
        NavigationStack {
            Form {
                infoSection
                settingsSection
                framesSection
            }
            .navigationTitle("视频抽帧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加 \(selected.count) 帧") {
                        let chosen = frames.filter { selected.contains($0.id) }
                        onConfirm(chosen, duration)
                        dismiss()
                    }
                    .disabled(selected.isEmpty || isExtracting)
                }
            }
            .sheet(item: $previewFrame) { frame in
                FramePreview(frame: frame)
            }
        }
        .onAppear {
            if frames.isEmpty && !isExtracting { startExtraction() }
        }
        .onDisappear {
            extractionTask?.cancel()
            try? FileManager.default.removeItem(at: session.url)
        }
    }

    // MARK: Sections

    private var infoSection: some View {
        Section {
            LabeledContent("时长", value: duration > 0 ? Format.duration(duration) : "读取中…")
            if videoSize != .zero {
                LabeledContent("分辨率", value: "\(Int(videoSize.width)) × \(Int(videoSize.height))")
            }
            if session.fileSize > 0 {
                LabeledContent("文件大小", value: Format.bytes(session.fileSize))
            }
        }
    }

    private var settingsSection: some View {
        Section {
            Picker("抽帧方式", selection: $settings.videoFrameMode) {
                ForEach(FrameSamplingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch settings.videoFrameMode {
            case .uniform:
                Stepper("帧数：\(settings.videoFrameCount)", value: $settings.videoFrameCount, in: 1...32)
            case .interval:
                Stepper(value: $settings.videoFrameInterval, in: 0.5...60, step: 0.5) {
                    Text("每 \(settings.videoFrameInterval, format: .number.precision(.fractionLength(1))) 秒一帧")
                }
                Stepper("最多：\(settings.videoMaxFrames) 帧", value: $settings.videoMaxFrames, in: 1...64)
            }

            Picker("帧分辨率（最长边）", selection: $settings.videoFrameMaxDimension) {
                ForEach([384, 512, 768, 1024, 1280], id: \.self) { value in
                    Text("\(value) px").tag(value)
                }
            }

            Button {
                startExtraction()
            } label: {
                if isExtracting {
                    HStack {
                        ProgressView(value: progress)
                        Text("\(Int(progress * 100))%").monospacedDigit()
                    }
                } else {
                    Label("重新抽帧", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isExtracting)
        } header: {
            Text("抽帧设置")
        } footer: {
            Text("帧越多、分辨率越高，模型理解得越细，但请求更大、速度更慢。大多数视觉模型 6–12 帧即可。")
        }
    }

    private var framesSection: some View {
        Section {
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            } else if frames.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("正在解码视频…")
                    Spacer()
                }
                .padding(.vertical, 30)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(frames) { frame in
                        FrameCell(frame: frame, isSelected: selected.contains(frame.id))
                            .onTapGesture { toggle(frame) }
                            .onLongPressGesture { previewFrame = frame }
                    }
                }
                .padding(.vertical, 6)
            }
        } header: {
            HStack {
                Text("已选 \(selected.count) / \(frames.count) 帧")
                Spacer()
                if !frames.isEmpty {
                    Text(selected.count == frames.count ? "全不选" : "全选")
                        .foregroundStyle(Color.accentColor)
                        .onTapGesture {
                            selected = selected.count == frames.count ? [] : Set(frames.map(\.id))
                        }
                }
            }
        } footer: {
            if !frames.isEmpty {
                let total = frames.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.image.data.count }
                Text("点击选择 / 取消，长按查看大图。已选帧合计约 \(Format.bytes(total))。")
            }
        }
    }

    // MARK: Actions

    private func toggle(_ frame: ExtractedFrame) {
        if selected.contains(frame.id) {
            selected.remove(frame.id)
        } else {
            selected.insert(frame.id)
        }
    }

    private func startExtraction() {
        extractionTask?.cancel()
        isExtracting = true
        errorText = nil
        progress = 0
        let url = session.url
        let currentSettings = settings

        extractionTask = Task {
            do {
                let result = try await VideoFrameExtractor.extract(from: url, settings: currentSettings) { value in
                    Task { @MainActor in progress = value }
                }
                frames = result.frames
                selected = Set(result.frames.map(\.id))
                duration = result.duration
                videoSize = result.naturalSize
            } catch is CancellationError {
                return
            } catch {
                errorText = "抽帧失败：\(error.localizedDescription)"
            }
            isExtracting = false
        }
    }
}

private struct FrameCell: View {
    let frame: ExtractedFrame
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image = frame.thumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.gray.opacity(0.2)
                }
            }
            .frame(minWidth: 96, maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            .opacity(isSelected ? 1 : 0.45)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.4))
                .padding(5)
        }
        .overlay(alignment: .bottomLeading) {
            Text(Format.timestamp(frame.time))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.6)))
                .padding(5)
        }
        .contentShape(Rectangle())
    }
}

private struct FramePreview: View {
    @Environment(\.dismiss) private var dismiss
    let frame: ExtractedFrame

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let image = frame.thumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
                Text("\(frame.image.width) × \(frame.image.height) · \(Format.bytes(frame.image.data.count))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .navigationTitle(Format.timestamp(frame.time))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
