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
            }
            .navigationTitle(conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPinned) {
                PinnedMessagesSheet(conversationID: conversationID)
            }
            .onAppear {
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
                "需要你的确认",
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
                        .accessibilityLabel(showBrowser ? "收起浏览器" : "显示浏览器")
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
                allowedContentTypes: [.image, .movie, .video],
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
                                title: "上下文从这里开始",
                                systemImage: "scissors",
                                actionTitle: "取消"
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
                            ContextDivider(title: "以上内容来自原对话，以下是这个分支的新内容", systemImage: "arrow.triangle.branch")
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

            if let status = isExtractingMemory ? "正在从对话中提取记忆…" : store.maintenanceStatus[conversationID] {
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
                    Button("从文件选择", systemImage: "folder") { showFileImporter = true }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                }
                .disabled(processingText != nil)
                .accessibilityLabel("添加图片或视频")

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
    }

    private var canSend: Bool {
        processingText == nil && (!inputText.isBlank || !pendingAttachments.isEmpty)
    }

    private var pendingSummary: String {
        let total = pendingAttachments.reduce(0) { $0 + $1.byteCount }
        let original = pendingAttachments.reduce(0) { $0 + $1.originalByteCount }
        let frames = pendingAttachments.filter { $0.kind == .videoFrame }.count
        let images = pendingAttachments.count - frames
        var parts: [String] = []
        if images > 0 { parts.append("\(images) 张图片") }
        if frames > 0 { parts.append("\(frames) 个视频帧") }
        var text = parts.joined(separator: " + ") + " · 共 \(Format.bytes(total))"
        if original > total { text += "（原始 \(Format.bytes(original))）" }
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
                    processingText = "正在读取视频…" + progress
                    if let movie = try await item.loadTransferable(type: MovieFile.self) {
                        enqueueVideo(VideoSession(url: movie.url, fileSize: AttachmentFactory.fileSize(movie.url)))
                    }
                } else {
                    processingText = "正在压缩图片…" + progress
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    if let attachment = await AttachmentFactory.image(from: data, settings: settings) {
                        pendingAttachments.append(attachment)
                    } else {
                        errorMessage = "无法读取这张图片。"
                    }
                }
            } catch {
                errorMessage = "导入失败：\(error.localizedDescription)"
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
                    processingText = "正在读取视频…" + progress
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                    try FileManager.default.copyItem(at: url, to: destination)
                    enqueueVideo(VideoSession(url: destination, fileSize: AttachmentFactory.fileSize(destination)))
                } else {
                    processingText = "正在压缩图片…" + progress
                    let data = try Data(contentsOf: url)
                    if let attachment = await AttachmentFactory.image(from: data, settings: settings) {
                        pendingAttachments.append(attachment)
                    } else {
                        errorMessage = "无法读取图片：\(url.lastPathComponent)"
                    }
                }
            } catch {
                errorMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    private func extractMemories() async {
        isExtractingMemory = true
        defer { isExtractingMemory = false }
        do {
            let items = try await store.extractMemoryCandidates(from: conversationID)
            if items.isEmpty {
                infoMessage = "这次对话里没有发现需要新记住的信息。"
            } else {
                memoryCandidates = MemoryCandidateBatch(texts: items)
            }
        } catch {
            errorMessage = "提取记忆失败：" + LLMError.friendlyDescription(error)
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
        processingText = "正在保存视频帧…"
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
