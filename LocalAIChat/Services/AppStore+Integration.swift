import AppIntents
import Foundation

/// 系统集成：跳转链接、Siri / 快捷指令、操作按钮
extension AppStore {
    // MARK: - 跳转链接

    func handleDeepLink(_ url: URL) {
        guard url.scheme == DeepLink.scheme else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        switch url.host {
        case "new":
            openNewChat(agentRef: value("agent"), voice: value("voice") == "1")
        case "conversation":
            if let id = value("id").flatMap(UUID.init), conversation(id: id) != nil {
                navigate(to: id)
            }
        default:
            break
        }
    }

    /// 按 ID 或名称查找助手（找不到时返回 nil）
    func resolveAgent(_ reference: String?) -> Agent? {
        guard let reference = reference?.trimmed, !reference.isEmpty else { return nil }
        if let id = UUID(uuidString: reference), let agent = agent(id: id) { return agent }
        if let exact = agents.first(where: { $0.name.compare(reference, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame }) {
            return exact
        }
        return agents.first { $0.name.localizedCaseInsensitiveContains(reference) || reference.localizedCaseInsensitiveContains($0.name) }
    }

    /// 新建对话并跳转过去。可以预填文字 / 图片、直接发送，或打开语音输入。
    @discardableResult
    func openNewChat(
        agentRef: String? = nil,
        agentID: UUID? = nil,
        voice: Bool = false,
        text: String? = nil,
        attachments: [Attachment] = [],
        sendImmediately: Bool = false
    ) -> UUID? {
        let target = agentID.flatMap { agent(id: $0) } ?? resolveAgent(agentRef) ?? agents.first
        guard let target else { return nil }
        let conversationID = newConversation(for: target.id)
        let content = text?.trimmed ?? ""
        if sendImmediately && (!content.isEmpty || !attachments.isEmpty) {
            send(text: content, attachments: attachments, in: conversationID)
        } else if !content.isEmpty || !attachments.isEmpty {
            pendingDrafts[conversationID] = Draft(text: content, attachments: attachments)
        }
        if voice {
            voiceRequest = conversationID
        }
        navigate(to: conversationID)
        return conversationID
    }

    // MARK: - Siri / 快捷指令直接提问

    enum IntentError: LocalizedError {
        case noAgent
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noAgent: return String(localized: "还没有可用的助手，请先打开 App 创建一个。")
            case .failed(let message): return message
            }
        }
    }

    /// 在后台向助手提问并等待回答。问答会保存在该助手的「Siri 与快捷指令」对话里。
    func askFromIntent(agentID: UUID?, question: String) async throws -> String {
        guard let target = agentID.flatMap({ agent(id: $0) }) ?? agents.first else { throw IntentError.noAgent }

        // 每个助手使用一个固定的对话保存来自 Siri / 快捷指令的问答
        let conversationID: UUID
        if let existing = conversations.first(where: { $0.agentID == target.id && $0.title == Self.intentConversationTitle }) {
            conversationID = existing.id
        } else {
            conversationID = newConversation(for: target.id)
            renameConversation(conversationID, to: Self.intentConversationTitle)
        }
        guard !isGenerating(conversationID) else {
            throw IntentError.failed(String(localized: "这个助手正在回答上一个问题，请稍后再试。"))
        }

        send(text: question, attachments: [], in: conversationID)
        // 等待这次回答完成
        if let task = tasks[conversationID] {
            await task.value
        }
        guard let reply = conversation(id: conversationID)?.messages.last, reply.role == .assistant else {
            throw IntentError.failed(String(localized: "没有得到回答。"))
        }
        if reply.isError {
            throw IntentError.failed(reply.errorText ?? reply.content)
        }
        let answer = ThinkParser.split(reply.content).answer.trimmed
        guard !answer.isEmpty else { throw IntentError.failed(String(localized: "没有得到回答。")) }
        saveNow()
        return answer
    }

    static let intentConversationTitle = String(localized: "Siri 与快捷指令")

    /// 助手列表变化后，更新 Siri 短语里可以说出的助手名称
    func refreshAppShortcuts() {
        LocalAIShortcuts.updateAppShortcutParameters()
    }
}
