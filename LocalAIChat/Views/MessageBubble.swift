import SwiftUI

struct MessageBubble: View {
    @Environment(AppStore.self) private var store
    let message: ChatMessage
    let agent: Agent?
    let conversationID: UUID
    let isStreaming: Bool
    let isLast: Bool

    @State private var showThinking = false
    @State private var previewAttachment: Attachment?
    @State private var showSelectableText = false

    private var isUser: Bool { message.role == .user }
    /// 旧版本保存的错误消息（错误文字直接写在内容里）
    private var isLegacyError: Bool { message.isError && message.errorText == nil }

    var body: some View {
        let parsed = ThinkParser.split(message.content)
        let thinking = [message.reasoning.trimmed, parsed.thinking].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let answer = parsed.answer

        HStack(alignment: .top, spacing: 8) {
            if isUser {
                Spacer(minLength: 48)
            } else {
                AgentAvatar(avatar: agent?.avatar ?? "🤖", size: 34)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if message.isPinned || message.isExcluded {
                    contextBadge
                }

                if !message.attachments.isEmpty {
                    let documents = message.attachments.filter { $0.kind == .document }
                    let visual = message.attachments.filter(\.isVisual)
                    ForEach(documents) { document in
                        DocumentChip(attachment: document)
                            .onTapGesture { previewAttachment = document }
                            .contextMenu { menuItems(answer: answer) }
                    }
                    if !visual.isEmpty {
                        AttachmentGrid(
                            attachments: visual,
                            alignTrailing: isUser,
                            onTap: { previewAttachment = $0 },
                            onAnnotate: { attachment in
                                store.annotationRequest = AnnotationRequest(conversationID: conversationID, fileName: attachment.fileName)
                            }
                        ) {
                            menuItems(answer: answer)
                        }
                    }
                }

                if let steps = message.steps, !steps.isEmpty {
                    AgentStepsView(steps: steps)
                }

                if !thinking.isEmpty {
                    DisclosureGroup(isExpanded: $showThinking) {
                        Text(thinking)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        Label(isStreaming && answer.isEmpty ? "思考中…" : "思考过程", systemImage: "brain")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemFill)))
                }

                if !answer.isEmpty {
                    Text(Self.markdown(answer))
                        .font(.body)
                        .foregroundStyle(isUser ? Color.white : (isLegacyError ? Color.red : Color.primary))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(bubbleBackground)
                        .contextMenu { menuItems(answer: answer) }
                } else if isStreaming && thinking.isEmpty {
                    TypingIndicator()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(bubbleBackground)
                }

                if let errorText = message.errorText, message.isError, !isStreaming {
                    FailureBox(
                        errorText: errorText,
                        showActions: isLast,
                        canContinue: !answer.isBlank && agent?.browserEnabled != true,
                        onRetry: { store.regenerate(in: conversationID) },
                        onContinue: { store.continueReply(in: conversationID) }
                    )
                }

                if !isUser, let model = message.modelName, !isStreaming, !answer.isEmpty {
                    Text([model, store.usageCaption(for: message, agent: agent)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }

            if !isUser {
                Spacer(minLength: 48)
            }
        }
        .opacity(message.isExcluded ? 0.45 : 1)
        .sheet(item: $previewAttachment) { attachment in
            AttachmentPreview(attachment: attachment)
        }
        .sheet(isPresented: $showSelectableText) {
            SelectableTextSheet(text: answer)
        }
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isUser ? Color.accentColor : (isLegacyError ? Color.red.opacity(0.1) : Color(.secondarySystemBackground)))
    }

    @ViewBuilder
    private func menuItems(answer: String) -> some View {
        Button("复制", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = answer
        }
        Button("选择文本", systemImage: "selection.pin.in.out") {
            showSelectableText = true
        }
        if !isUser && isLast && !isStreaming {
            Button("重新生成", systemImage: "arrow.clockwise") {
                store.regenerate(in: conversationID)
            }
        }
        if !isStreaming {
            Section("上下文") {
                Button(message.isPinned ? "取消置顶" : "置顶到上下文", systemImage: message.isPinned ? "pin.slash" : "pin") {
                    store.togglePin(message.id, in: conversationID)
                }
                Button(message.isExcluded ? "重新发送给模型" : "不发送给模型", systemImage: message.isExcluded ? "eye" : "eye.slash") {
                    store.toggleExclude(message.id, in: conversationID)
                }
                Button("从这里开始新的上下文", systemImage: "scissors") {
                    store.setContextStart(message.id, in: conversationID)
                }
            }
            Section("分支") {
                Button("从这里分叉", systemImage: "arrow.triangle.branch") {
                    if let forkID = store.forkConversation(conversationID, at: message.id, includeMessage: true) {
                        store.navigate(to: forkID)
                    }
                }
                if isUser {
                    Button("编辑并分叉", systemImage: "pencil.and.list.clipboard") {
                        if let forkID = store.forkForEditing(conversationID, at: message.id) {
                            store.navigate(to: forkID)
                        }
                    }
                }
            }
            Button("删除", systemImage: "trash", role: .destructive) {
                store.deleteMessage(message.id, in: conversationID)
            }
        }
    }

    /// 置顶 / 排除的标记
    private var contextBadge: some View {
        Group {
            if message.isPinned {
                Label("已置顶，始终发送给模型", systemImage: "pin.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("不发送给模型", systemImage: "eye.slash")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// 生成失败时显示的错误和操作按钮
private struct FailureBox: View {
    let errorText: String
    let showActions: Bool
    let canContinue: Bool
    let onRetry: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(errorText)
                    .font(.footnote)
            } icon: {
                Image(systemName: "wifi.exclamationmark")
            }
            .foregroundStyle(.red)

            if showActions {
                HStack(spacing: 10) {
                    if canContinue {
                        Button(action: onContinue) {
                            Label("从断点继续", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button(action: onRetry) {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.footnote)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.08)))
    }
}

/// 工具调用步骤（浏览器操作）列表，步骤多时可折叠
private struct AgentStepsView: View {
    let steps: [AgentStep]
    @State private var expanded = false

    var body: some View {
        let visible = expanded || steps.count <= 4 ? steps : Array(steps.suffix(3))
        VStack(alignment: .leading, spacing: 6) {
            if steps.count > 4 {
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Label(expanded ? "收起步骤" : "共 \(steps.count) 个步骤，显示全部", systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            ForEach(visible) { step in
                HStack(spacing: 8) {
                    Image(systemName: step.icon)
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                    Text(step.title)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    statusIcon(step.status)
                }
                .font(.footnote)
            }
        }
        .padding(10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemFill)))
    }

    @ViewBuilder
    private func statusIcon(_ status: AgentStep.Status) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .denied:
            Image(systemName: "hand.raised.fill").foregroundStyle(.red)
        }
    }
}

private struct TypingIndicator: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(animate ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.2), value: animate)
            }
        }
        .onAppear { animate = true }
    }
}

private struct SelectableTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("选择文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Attachments

struct AttachmentThumbnail: View {
    let attachment: Attachment
    var size: CGFloat = 80
    var showSize = false

    var body: some View {
        ZStack {
            if attachment.kind == .document {
                // 文档：图标 + 文件名
                VStack(spacing: 4) {
                    Image(systemName: DocumentChip.icon(for: attachment))
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(Color.accentColor)
                    Text(attachment.displayName ?? "文档")
                        .font(.system(size: 9))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.secondarySystemBackground))
            } else if let image = ImageCache.shared.image(for: attachment.fileName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.2)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if attachment.kind == .videoFrame, let time = attachment.timestamp {
                badge(Label(Format.timestamp(time), systemImage: "video.fill"))
            } else if showSize {
                badge(Text(Format.bytes(attachment.byteCount)))
            }
        }
    }

    private func badge(_ content: some View) -> some View {
        content
            .font(.system(size: 9, weight: .semibold))
            .labelStyle(CompactLabelStyle())
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.6)))
            .padding(4)
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}

private struct AttachmentGrid<MenuItems: View>: View {
    let attachments: [Attachment]
    let alignTrailing: Bool
    let onTap: (Attachment) -> Void
    let onAnnotate: (Attachment) -> Void
    @ViewBuilder let menuItems: () -> MenuItems

    var body: some View {
        let size: CGFloat = attachments.count == 1 ? 180 : 86
        let columns = Array(repeating: GridItem(.fixed(size), spacing: 6), count: min(attachments.count, 3))
        LazyVGrid(columns: columns, alignment: alignTrailing ? .trailing : .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                AttachmentThumbnail(attachment: attachment, size: size)
                    .onTapGesture { onTap(attachment) }
                    .contextMenu {
                        Button("用 Pencil 标注并提问", systemImage: "pencil.tip.crop.circle") {
                            onAnnotate(attachment)
                        }
                        Divider()
                        menuItems()
                    }
            }
        }
        .fixedSize()
    }
}

/// 消息中的文档附件
struct DocumentChip: View {
    let attachment: Attachment

    static func icon(for attachment: Attachment) -> String {
        let name = (attachment.displayName ?? "").lowercased()
        if name.hasSuffix(".pdf") { return "doc.richtext.fill" }
        if name.hasSuffix(".md") || name.hasSuffix(".txt") { return "doc.plaintext.fill" }
        if name.hasSuffix(".csv") { return "tablecells.fill" }
        if name.hasSuffix(".json") || name.hasSuffix(".xml") { return "curlybraces.square.fill" }
        return "doc.text.fill"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.icon(for: attachment))
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayName ?? "文档")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: 280, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }

    private var detail: String {
        var parts: [String] = []
        if let pages = attachment.pageCount { parts.append("\(pages) 页") }
        if let length = attachment.textLength { parts.append("\(length.formatted()) 字") }
        if length > AppStore.documentCharacterLimit { parts.append("超出部分不会发送") }
        return parts.joined(separator: " · ")
    }

    private var length: Int { attachment.textLength ?? 0 }
}

struct AttachmentPreview: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: Attachment

    var body: some View {
        if attachment.kind == .document {
            DocumentPreview(attachment: attachment)
        } else {
            imagePreview
        }
    }

    private var imagePreview: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image = ImageCache.shared.image(for: attachment.fileName) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }
                VStack(spacing: 6) {
                    if attachment.kind == .videoFrame, let time = attachment.timestamp {
                        Text("视频帧 · \(Format.timestamp(time))")
                            .font(.headline)
                    }
                    Text("\(attachment.width) × \(attachment.height) 像素")
                    if attachment.kind == .image && attachment.originalByteCount > attachment.byteCount {
                        Text("压缩：\(Format.bytes(attachment.originalByteCount)) → \(Format.bytes(attachment.byteCount))")
                    } else {
                        Text("大小：\(Format.bytes(attachment.byteCount))")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top)
            .navigationTitle(attachment.kind == .image ? "图片" : "视频帧")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// 查看文档提取出的文字
private struct DocumentPreview: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: Attachment
    @State private var text: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DocumentChip(attachment: attachment)
                    if let text {
                        Text(text.count > 20000 ? String(text.prefix(20000)) + "\n……" : text)
                            .font(.callout)
                            .textSelection(.enabled)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("文档内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                let fileName = attachment.fileName
                text = await Task.detached { Storage.loadText(fileName) ?? "" }.value
            }
        }
    }
}
