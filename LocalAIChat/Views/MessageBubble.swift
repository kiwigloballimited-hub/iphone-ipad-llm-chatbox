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
                if !message.attachments.isEmpty {
                    AttachmentGrid(attachments: message.attachments, alignTrailing: isUser) { previewAttachment = $0 }
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
                        .foregroundStyle(isUser ? Color.white : (message.isError ? Color.red : Color.primary))
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

                if !isUser, let model = message.modelName, !isStreaming, !answer.isEmpty {
                    Text(model)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }

            if !isUser {
                Spacer(minLength: 48)
            }
        }
        .sheet(item: $previewAttachment) { attachment in
            AttachmentPreview(attachment: attachment)
        }
        .sheet(isPresented: $showSelectableText) {
            SelectableTextSheet(text: answer)
        }
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isUser ? Color.accentColor : (message.isError ? Color.red.opacity(0.1) : Color(.secondarySystemBackground)))
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
            Button("删除", systemImage: "trash", role: .destructive) {
                store.deleteMessage(message.id, in: conversationID)
            }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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
            if let image = ImageCache.shared.image(for: attachment.fileName) {
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

private struct AttachmentGrid: View {
    let attachments: [Attachment]
    let alignTrailing: Bool
    let onTap: (Attachment) -> Void

    var body: some View {
        let size: CGFloat = attachments.count == 1 ? 180 : 86
        let columns = Array(repeating: GridItem(.fixed(size), spacing: 6), count: min(attachments.count, 3))
        LazyVGrid(columns: columns, alignment: alignTrailing ? .trailing : .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                AttachmentThumbnail(attachment: attachment, size: size)
                    .onTapGesture { onTap(attachment) }
            }
        }
        .fixedSize()
    }
}

struct AttachmentPreview: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: Attachment

    var body: some View {
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
