import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 待处理的视频（用于弹出抽帧界面）
struct VideoSession: Identifiable {
    let id = UUID()
    let url: URL
    let fileSize: Int
}

struct ChatView: View {
    @Environment(AppStore.self) private var store
    let conversationID: UUID

    @State private var inputText = ""
    @State private var pendingAttachments: [Attachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var processingText: String?
    @State private var videoQueue: [VideoSession] = []
    @State private var activeVideo: VideoSession?
    @State private var errorMessage: String?
    @State private var showClearConfirm = false
    @State private var infoMessage: String?
    @State private var isExtractingMemory = false
    @State private var memoryCandidates: MemoryCandidateBatch?
    @State private var showMemoryBook = false
    @State private var showSummary = false
    @State private var showBrowser = false
    @State private var showUsage = false
    @State private var showPinned = false
    @State private var showVoice = false
    @State private var annotationSource: AnnotationSource?
    @State private var showAnnotatePicker = false
    @State private var annotateItem: PhotosPickerItem?
    @State private var isDropTargeted = false
    @FocusState private var inputFocused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if let conversation = store.conversation(id: conversationID) {
            let agent = store.agent(id: conversation.agentID)
            let generating = store.isGenerating(conversationID)

            let browser = store.browserSessions[conversationID]

            layout(browser: browser) {
                VStack(spacing: 0) {
                    messageList(conversation: conversation, agent: agent, generating: generating)
                    inputBar(generating: generating)
                }
                // 从「文件」、Safari 等拖入图片、PDF、文本、视频、链接
                .onDrop(of: Self.droppableTypes, isTargeted: $isDropTargeted) { providers in
                    Task { await importDropped(providers) }
                    return true
                }
                .overlay {
                    if isDropTargeted {
                        DropTargetOverlay()
                    }
                }
            }
            .navigationTitle(conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPinned) {
                PinnedMessagesSheet(conversationID: conversationID)
            }
            .sheet(item: $annotationSource) { source in
                PencilSheet(background: source.image) { attachments, suggestion in
                    pendingAttachments.append(contentsOf: attachments)
                    if !suggestion.isEmpty {
                        inputText = inputText.isBlank ? suggestion : suggestion + "\n" + inputText
                    }
                } onInsertText: { text in
                    inputText = inputText.isBlank ? text : inputText + "\n" + text
                }
            }
            .onChange(of: store.annotationRequest) { _, request in
                // 在消息里的图片上选择了「用 Pencil 标注」
                guard let request, request.conversationID == conversationID else { return }
                store.annotationRequest = nil
                annotationSource = AnnotationSource(image: ImageCache.shared.image(for: request.fileName))
            }
            .sheet(isPresented: $showVoice) {
                VoiceInputSheet(agent: agent) { text in
                    store.send(text: text, attachments: pendingAttachments, in: conversationID)
                    pendingAttachments = []
                } onInsert: { text in
                    inputText = inputText.isBlank ? text : inputText + " " + text
                }
            }
            .onChange(of: store.voiceRequest) { _, request in
                // 操作按钮 / Siri / 小组件请求语音提问
                if request == conversationID {
                    store.voiceRequest = nil
                    showVoice = true
                }
            }
            .onAppear {
                if store.voiceRequest == conversationID {
                    store.voiceRequest = nil
                    showVoice = true
                }
                // 「编辑并分叉」带过来的草稿
                if let draft = store.takeDraft(for: conversationID) {
                    inputText = draft.text
                    pendingAttachments = draft.attachments
                    inputFocused = true
                }
            }
            .sheet(isPresented: $showUsage) {
                UsageDetailSheet(conversationID: conversationID, draft: inputText)
            }
            .task(id: agent.map { "\($0.id)|\(store.effectiveModel(for: $0))|\($0.serverID?.uuidString ?? "")" }) {
                // 打开对话时自动检测上下文窗口
                if let agent { await store.detectContextWindowIfNeeded(for: agent) }
            }
            .onChange(of: browser != nil) { _, hasBrowser in
                // AI 开始使用浏览器时自动展开
                if hasBrowser { withAnimation { showBrowser = true } }
            }
            .alert(
                String(localized: "需要你的确认"),
                isPresented: Binding(
                    get: { store.pendingConfirmations[conversationID] != nil },
                    set: { presented in
                        if !presented && store.pendingConfirmations[conversationID] != nil {
                            store.resolveConfirmation(conversationID, approved: false)
                        }
                    }
                )
            ) {
                Button("拒绝", role: .cancel) { store.resolveConfirmation(conversationID, approved: false) }
                Button("允许") { store.resolveConfirmation(conversationID, approved: true) }
            } message: {
                Text(store.pendingConfirmations[conversationID] ?? "")
            }
            .toolbar {
                if agent?.browserEnabled == true || browser != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            if browser == nil {
                                let session = store.browser(for: conversationID)
                                if session.currentURL.isEmpty, let url = URL(string: "https://www.bing.com") {
                                    Task { await session.load(url) }
                                }
                            }
                            withAnimation { showBrowser.toggle() }
                        } label: {
                            Image(systemName: showBrowser ? "globe.badge.chevron.backward" : "globe")
                        }
                        .accessibilityLabel(showBrowser ? String(localized: "收起浏览器") : String(localized: "显示浏览器"))
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let agent {
                            Text("\(agent.avatar) \(agent.name) · \(store.effectiveModel(for: agent))")
                        }
                        if let agent {
                            Picker(selection: Binding(
                                get: { agent.thinking },
                                set: { store.setThinking($0, for: agent.id) }
                            )) {
                                ForEach(ThinkingLevel.allCases) { level in
                                    Text(level.displayName).tag(level)
                                }
                            } label: {
                                Label("思考强度：\(agent.thinking.displayName)", systemImage: "brain")
                            }
                            .pickerStyle(.menu)
                        }
                        Section("上下文") {
                            Button("置顶的消息（\(store.pinnedMessages(in: conversationID).count)）", systemImage: "pin") {
                                showPinned = true
                            }
                            if conversation.contextStartsAt != nil {
                                Button("取消上下文起点", systemImage: "scissors") {
                                    store.setContextStart(nil, in: conversationID)
                                }
                            }
                            if let last = conversation.messages.last, !generating {
                                Button("复制为新分支", systemImage: "arrow.triangle.branch") {
                                    if let forkID = store.forkConversation(conversationID, at: last.id, includeMessage: true) {
                                        store.navigate(to: forkID)
                                    }
                                }
                            }
                        }
                        Section("记忆") {
                            Button("记住这次对话", systemImage: "brain.head.profile") {
                                Task { await extractMemories() }
                            }
                            .disabled(generating || isExtractingMemory)
                            Button("查看记忆本（\(store.memories(for: conversation.agentID).count)）", systemImage: "book.closed") {
                                showMemoryBook = true
                            }
                            if conversation.summary != nil {
                                Button("查看早期对话摘要", systemImage: "text.alignleft") {
                                    showSummary = true
                                }
                            }
                        }
                        Button("重新生成最后回复", systemImage: "arrow.clockwise") {
                            store.regenerate(in: conversationID)
                        }
                        .disabled(generating || !conversation.messages.contains { $0.role == .user })
                        Button("清空对话", systemImage: "trash", role: .destructive) {
                            showClearConfirm = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photoItems,
                maxSelectionCount: 10,
                matching: .any(of: [.images, .videos]),
                preferredItemEncoding: .current
            )
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task { await importPhotoItems(items) }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.image, .movie, .video] + DocumentImporter.supportedTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls): Task { await importFiles(urls) }
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .sheet(item: $activeVideo, onDismiss: presentNextVideo) { session in
                VideoFramePickerView(session: session, initialSettings: store.media) { frames, duration in
                    Task { await addVideoFrames(frames, duration: duration, session: session) }
                }
            }
            .alert("出错了", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $memoryCandidates) { batch in
                MemoryCandidatesSheet(batch: batch) { texts in
                    store.acceptMemories(texts, from: conversationID)
                }
            }
            .sheet(isPresented: $showMemoryBook) {
                MemoryBookSheet(agentID: conversation.agentID)
            }
            .sheet(isPresented: $showSummary) {
                ConversationSummarySheet(conversationID: conversationID)
            }
            .alert("提示", isPresented: Binding(get: { infoMessage != nil }, set: { if !$0 { infoMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(infoMessage ?? "")
            }
            .confirmationDialog("清空当前对话的所有消息？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) { store.clearConversation(conversationID) }
            }
            .onDisappear {
                // 未发送的附件不再需要
                if !pendingAttachments.isEmpty {
                    let files = pendingAttachments.map(\.fileName)
                    pendingAttachments = []
                    Task.detached { files.forEach(Storage.deleteAttachment) }
                }
            }
        } else {
            ContentUnavailableView("对话不存在", systemImage: "bubble.left")
        }
    }

    // MARK: - Layout

    /// iPad 横向宽屏：聊天和浏览器左右并排；iPhone：浏览器在聊天上方，可折叠
    @ViewBuilder
    private func layout<Chat: View>(browser: BrowserSession?, @ViewBuilder chat: () -> Chat) -> some View {
        if let browser, showBrowser, sizeClass == .regular {
            HStack(spacing: 0) {
                chat()
                    .frame(maxWidth: .infinity)
                Divider()
                BrowserPanel(session: browser) { withAnimation { showBrowser = false } }
                    .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                if let browser {
                    if showBrowser {
                        BrowserPanel(session: browser) { withAnimation { showBrowser = false } }
                            .frame(height: 320)
                    } else {
                        BrowserStatusBar(session: browser) { withAnimation { showBrowser = true } }
                    }
                    Divider()
                }
                chat()
            }
        }
    }

    // MARK: - Messages

    private func messageList(conversation: Conversation, agent: Agent?, generating: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if conversation.messages.isEmpty {
                        EmptyChatHint(agent: agent)
                            .padding(.top, 60)
                    }
                    if conversation.parentID != nil {
                        ForkBanner(conversation: conversation)
                    }
                    let contextStartID = conversation.contextStartsAt.flatMap { start in
                        conversation.messages.first { $0.createdAt >= start }?.id
                    }
                    ForEach(conversation.messages) { message in
                        if message.id == contextStartID {
                            ContextDivider(
                                title: String(localized: "上下文从这里开始"),
                                systemImage: "scissors",
                                actionTitle: String(localized: "取消")
                            ) {
                                store.setContextStart(nil, in: conversationID)
                            }
                        }
                        MessageBubble(
                            message: message,
                            agent: agent,
                            conversationID: conversationID,
                            isStreaming: generating && message.id == conversation.messages.last?.id,
                            isLast: message.id == conversation.messages.last?.id
                        )
                        .id(message.id)
                        if message.id == conversation.forkPointMessageID && message.id != conversation.messages.last?.id {
                            ContextDivider(title: String(localized: "以上内容来自原对话，以下是这个分支的新内容"), systemImage: "arrow.triangle.branch")
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: conversation.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: conversation.messages.last?.content) { _, _ in
                if generating { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: - Input bar

    private func inputBar(generating: Bool) -> some View {
        VStack(spacing: 8) {
            if let stats = store.sessionStats(for: conversationID, draft: inputText) {
                Button {
                    showUsage = true
                } label: {
                    UsageStrip(stats: stats)
                }
                .buttonStyle(.plain)
            }

            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { attachment in
                            AttachmentThumbnail(attachment: attachment, size: 64, showSize: true)
                                .contextMenu {
                                    if attachment.isVisual {
                                        Button("用 Pencil 标注", systemImage: "pencil.tip.crop.circle") {
                                            annotationSource = AnnotationSource(image: ImageCache.shared.image(for: attachment.fileName))
                                        }
                                    }
                                    Button("移除", systemImage: "trash", role: .destructive) {
                                        removePending(attachment)
                                    }
                                }
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        removePending(attachment)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .offset(x: 6, y: -6)
                                }
                        }
                    }
                    .padding(.top, 6)
                    .padding(.horizontal, 2)
                }
                Text(pendingSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let status = store.retryStatus[conversationID] {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Label(status, systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                }
            }

            if let status = isExtractingMemory ? String(localized: "正在从对话中提取记忆…") : store.maintenanceStatus[conversationID] {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Label(status, systemImage: "brain.head.profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            if let processingText {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(processingText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button("照片 / 视频", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                    Button("从文件选择（图片 / PDF / 文本）", systemImage: "folder") { showFileImporter = true }
                    Divider()
                    Button("画板（手写 / 涂鸦）", systemImage: "pencil.and.scribble") {
                        annotationSource = AnnotationSource(image: nil)
                    }
                    Button("标注图片…", systemImage: "pencil.tip.crop.circle") { showAnnotatePicker = true }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                }
                .disabled(processingText != nil)
                .accessibilityLabel("添加图片或视频")

                Button {
                    showVoice = true
                } label: {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                }
                .disabled(generating)
                .accessibilityLabel("语音输入")

                TextField("输入消息…", text: $inputText, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemBackground)))

                if generating {
                    Button {
                        store.stopGeneration(conversationID)
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 30))
                    }
                    .accessibilityLabel("停止生成")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    }
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("发送")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .photosPicker(isPresented: $showAnnotatePicker, selection: $annotateItem, matching: .images)
        .onChange(of: annotateItem) { _, item in
            guard let item else { return }
            annotateItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    annotationSource = AnnotationSource(image: image)
                }
            }
        }
    }

    private var canSend: Bool {
        processingText == nil && (!inputText.isBlank || !pendingAttachments.isEmpty)
    }

    private var pendingSummary: String {
        let total = pendingAttachments.reduce(0) { $0 + $1.byteCount }
        let original = pendingAttachments.reduce(0) { $0 + $1.originalByteCount }
        let frames = pendingAttachments.filter { $0.kind == .videoFrame }.count
        let documents = pendingAttachments.filter { $0.kind == .document }.count
        let images = pendingAttachments.count - frames - documents
        var parts: [String] = []
        if images > 0 { parts.append(String(localized: "\(images) 张图片")) }
        if frames > 0 { parts.append(String(localized: "\(frames) 个视频帧")) }
        if documents > 0 { parts.append(String(localized: "\(documents) 个文档")) }
        var text = parts.joined(separator: " + ") + String(localized: " · 共 \(Format.bytes(total))")
        if original > total { text += String(localized: "（原始 \(Format.bytes(original))）") }
        return text
    }

    private func send() {
        guard canSend else { return }
        store.send(text: inputText.trimmed, attachments: pendingAttachments, in: conversationID)
        inputText = ""
        pendingAttachments = []
    }

    private func removePending(_ attachment: Attachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
        let file = attachment.fileName
        Task.detached { Storage.deleteAttachment(file) }
    }

    // MARK: - Import

    private func importPhotoItems(_ items: [PhotosPickerItem]) async {
        let settings = store.media
        defer { processingText = nil }
        for (index, item) in items.enumerated() {
            let progress = items.count > 1 ? " (\(index + 1)/\(items.count))" : ""
            do {
                if item.supportedContentTypes.contains(where: AttachmentFactory.isVideo) {
                    processingText = String(localized: "正在读取视频…") + progress
                    if let movie = try await item.loadTransferable(type: MovieFile.self) {
                        enqueueVideo(VideoSession(url: movie.url, fileSize: AttachmentFactory.fileSize(movie.url)))
                    }
                } else {
                    processingText = String(localized: "正在压缩图片…") + progress
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    if let attachment = await AttachmentFactory.image(from: data, settings: settings) {
                        pendingAttachments.append(attachment)
                    } else {
                        errorMessage = String(localized: "无法读取这张图片。")
                    }
                }
            } catch {
                errorMessage = String(localized: "导入失败：\(error.localizedDescription)")
            }
        }
    }

    private func importFiles(_ urls: [URL]) async {
        let settings = store.media
        defer { processingText = nil }
        for (index, url) in urls.enumerated() {
            let progress = urls.count > 1 ? " (\(index + 1)/\(urls.count))" : ""
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                ?? UTType(filenameExtension: url.pathExtension)
                ?? .data
            do {
                if AttachmentFactory.isVideo(type) {
                    processingText = String(localized: "正在读取视频…") + progress
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                    try FileManager.default.copyItem(at: url, to: destination)
                    enqueueVideo(VideoSession(url: destination, fileSize: AttachmentFactory.fileSize(destination)))
                } else if DocumentImporter.isDocument(type) {
                    processingText = String(localized: "正在读取文档…") + progress
                    let imported = await DocumentImporter.importFile(at: url, type: type, settings: settings)
                    pendingAttachments.append(contentsOf: imported.attachments)
                    if let note = imported.note { infoMessage = note }
                } else {
                    processingText = String(localized: "正在压缩图片…") + progress
                    let data = try Data(contentsOf: url)
                    if let attachment = await AttachmentFactory.image(from: data, settings: settings) {
                        pendingAttachments.append(attachment)
                    } else {
                        errorMessage = String(localized: "无法读取图片：\(url.lastPathComponent)")
                    }
                }
            } catch {
                errorMessage = String(localized: "导入失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Drag & Drop

    static let droppableTypes: [UTType] = [.image, .movie, .video, .pdf, .fileURL, .url, .text]

    /// 处理拖进来的内容：图片、视频、PDF / 文本文件、链接、文字
    private func importDropped(_ providers: [NSItemProvider]) async {
        let settings = store.media
        defer { processingText = nil }
        for (index, provider) in providers.enumerated() {
            let progress = providers.count > 1 ? " (\(index + 1)/\(providers.count))" : ""
            let types = provider.registeredContentTypes

            if let type = types.first(where: AttachmentFactory.isVideo) {
                processingText = String(localized: "正在读取视频…") + progress
                if let url = await DropLoader.copyFile(provider, type: type) {
                    enqueueVideo(VideoSession(url: url, fileSize: AttachmentFactory.fileSize(url)))
                }
            } else if types.contains(where: { $0.conforms(to: .image) }) {
                processingText = String(localized: "正在压缩图片…") + progress
                if let data = await DropLoader.data(provider, type: .image),
                   let attachment = await AttachmentFactory.image(from: data, settings: settings) {
                    pendingAttachments.append(attachment)
                }
            } else if types.contains(where: { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }),
                      let url = await DropLoader.url(provider), !url.isFileURL {
                // 网页链接：放进输入框
                inputText = inputText.isBlank ? url.absoluteString : inputText + "\n" + url.absoluteString
            } else if let type = types.first(where: DocumentImporter.isDocument),
                      type.conforms(to: .pdf) || DropLoader.looksLikeFile(provider),
                      let url = await DropLoader.copyFile(provider, type: type) {
                // PDF / 文本文件
                processingText = String(localized: "正在读取文档…") + progress
                let imported = await DocumentImporter.importFile(at: url, type: type, settings: settings)
                pendingAttachments.append(contentsOf: imported.attachments)
                if let note = imported.note { infoMessage = note }
                try? FileManager.default.removeItem(at: url)
            } else if let url = await DropLoader.fileURL(provider) {
                await importFiles([url])
            } else if let text = await DropLoader.text(provider), !text.isBlank {
                // 文字：短的放进输入框，长的作为文档附件
                if text.count > 2000 {
                    if let attachment = await DocumentImporter.importText(text, name: String(localized: "拖入的文字")) {
                        pendingAttachments.append(attachment)
                    }
                } else {
                    inputText = inputText.isBlank ? text : inputText + "\n" + text
                }
            }
        }
    }

    private func extractMemories() async {
        isExtractingMemory = true
        defer { isExtractingMemory = false }
        do {
            let items = try await store.extractMemoryCandidates(from: conversationID)
            if items.isEmpty {
                infoMessage = String(localized: "这次对话里没有发现需要新记住的信息。")
            } else {
                memoryCandidates = MemoryCandidateBatch(texts: items)
            }
        } catch {
            errorMessage = String(localized: "提取记忆失败：") + LLMError.friendlyDescription(error)
        }
    }

    private func enqueueVideo(_ session: VideoSession) {
        if activeVideo == nil {
            activeVideo = session
        } else {
            videoQueue.append(session)
        }
    }

    private func presentNextVideo() {
        guard !videoQueue.isEmpty else { return }
        let next = videoQueue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            activeVideo = next
        }
    }

    private func addVideoFrames(_ frames: [ExtractedFrame], duration: Double, session: VideoSession) async {
        processingText = String(localized: "正在保存视频帧…")
        let attachments = await AttachmentFactory.videoFrames(frames, duration: duration, originalByteCount: session.fileSize)
        pendingAttachments.append(contentsOf: attachments)
        processingText = nil
    }
}

private struct EmptyChatHint: View {
    let agent: Agent?

    var body: some View {
        VStack(spacing: 12) {
            AgentAvatar(avatar: agent?.avatar ?? "🤖", size: 72)
            Text(agent?.name ?? "")
                .font(.title2.bold())
            Text("发送消息开始对话，也可以点击 + 添加图片或视频")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 拖拽时覆盖在聊天区域上的提示
private struct DropTargetOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.accentColor.opacity(0.08)))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 44))
                    Text("松开以添加")
                        .font(.title3.weight(.semibold))
                    Text("图片 · PDF · 文本文件 · 视频 · 链接")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.accentColor)
            }
            .padding(12)
            .allowsHitTesting(false)
    }
}

/// NSItemProvider 的异步读取（拖拽）
enum DropLoader {
    static func data(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// 把拖进来的文件复制到临时目录（回调结束后原文件可能被删除）
    static func copyFile(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// 是文件（例如从「文件」App 拖来的 .txt），而不是网页上选中的一段文字
    static func looksLikeFile(_ provider: NSItemProvider) -> Bool {
        provider.suggestedName != nil && !provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier)
    }

    static func url(_ provider: NSItemProvider) async -> URL? {
        guard provider.canLoadObject(ofClass: URL.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    static func fileURL(_ provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        guard let url = await url(provider), url.isFileURL else { return nil }
        return url
    }

    static func text(_ provider: NSItemProvider) async -> String? {
        guard provider.canLoadObject(ofClass: String.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                continuation.resume(returning: text)
            }
        }
    }
}
