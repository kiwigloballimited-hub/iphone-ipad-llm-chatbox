import Foundation

/// 上下文工程：置顶、排除、上下文起点，以及分支对话
extension AppStore {
    // MARK: - 置顶 / 排除

    func togglePin(_ messageID: UUID, in conversationID: UUID) {
        updateMessage(messageID, in: conversationID) { message in
            message.pinned = !message.isPinned
            if message.isPinned { message.excluded = nil }
        }
    }

    func toggleExclude(_ messageID: UUID, in conversationID: UUID) {
        updateMessage(messageID, in: conversationID) { message in
            message.excluded = !message.isExcluded
            if message.isExcluded { message.pinned = nil }
        }
    }

    /// 设置上下文起点：这条消息之前的内容不再发送给模型（置顶的除外）。传 nil 取消。
    func setContextStart(_ messageID: UUID?, in conversationID: UUID) {
        guard let ci = conversationIndex(conversationID) else { return }
        if let messageID, let message = conversations[ci].messages.first(where: { $0.id == messageID }) {
            conversations[ci].contextStartsAt = message.createdAt
        } else {
            conversations[ci].contextStartsAt = nil
        }
        conversations[ci].contextEditedAt = Date()
        save()
    }

    func pinnedMessages(in conversationID: UUID) -> [ChatMessage] {
        conversation(id: conversationID)?.messages.filter(\.isPinned) ?? []
    }

    private func updateMessage(_ messageID: UUID, in conversationID: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let ci = conversationIndex(conversationID),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else { return }
        change(&conversations[ci].messages[mi])
        conversations[ci].contextEditedAt = Date()
        save()
    }

    // MARK: - 分支对话

    /// 从某条消息分叉出新对话。
    /// - includeMessage: true = 复制到这条消息（含）；false = 复制到这条消息之前（用于「编辑并分叉」）
    /// - Returns: 新对话的 ID
    @discardableResult
    func forkConversation(_ conversationID: UUID, at messageID: UUID, includeMessage: Bool) -> UUID? {
        guard let source = conversation(id: conversationID),
              let index = source.messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        let end = includeMessage ? index + 1 : index

        // 复制消息（新的 ID，图片文件也复制一份，删除任一对话都不影响另一个）
        var copies: [ChatMessage] = []
        for message in source.messages[..<end] {
            var copy = message
            copy.id = UUID()
            copy.usage = nil // 用量算在原对话里，分支只统计自己的新消耗
            copy.attachments = message.attachments.map(Self.duplicateAttachment)
            copies.append(copy)
        }

        var fork = Conversation(agentID: source.agentID)
        fork.title = source.title + " · 分支"
        fork.messages = copies
        fork.parentID = source.id
        fork.parentTitle = source.title
        fork.forkPointMessageID = copies.last?.id

        // 只保留仍然适用于分支的状态
        if let lastDate = copies.last?.createdAt {
            if let until = source.summaryCoversUntil, until <= lastDate {
                fork.summary = source.summary
                fork.summaryCoversUntil = until
            }
            if let start = source.contextStartsAt, start <= lastDate {
                fork.contextStartsAt = start
            }
            if let extracted = source.memoryExtractedUntil {
                fork.memoryExtractedUntil = min(extracted, lastDate)
            }
        }

        conversations.append(fork)
        save()
        return fork.id
    }

    /// 编辑并分叉：分支里不包含这条用户消息，而是把它放进输入框，修改后再发送
    @discardableResult
    func forkForEditing(_ conversationID: UUID, at messageID: UUID) -> UUID? {
        guard let source = conversation(id: conversationID),
              let message = source.messages.first(where: { $0.id == messageID }),
              let forkID = forkConversation(conversationID, at: messageID, includeMessage: false) else { return nil }
        pendingDrafts[forkID] = Draft(text: message.content, attachments: message.attachments.map(Self.duplicateAttachment))
        return forkID
    }

    /// 取出（并清除）新对话的预填内容
    func takeDraft(for conversationID: UUID) -> Draft? {
        pendingDrafts.removeValue(forKey: conversationID)
    }

    /// 请求界面切换到某个对话
    func navigate(to conversationID: UUID) {
        navigationTarget = conversationID
    }

    func branches(of conversationID: UUID) -> [Conversation] {
        conversations.filter { $0.parentID == conversationID }.sorted { $0.createdAt < $1.createdAt }
    }

    private static func duplicateAttachment(_ attachment: Attachment) -> Attachment {
        var copy = attachment
        copy.id = UUID()
        if let newName = Storage.duplicateAttachment(attachment.fileName) {
            copy.fileName = newName
        }
        return copy
    }
}

/// 预填到输入框的草稿
struct Draft {
    var text: String
    var attachments: [Attachment]
}
