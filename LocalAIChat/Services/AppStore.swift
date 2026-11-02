import Foundation
import Observation
import SwiftUI

/// 全局状态：服务器、助手、对话、媒体设置，以及生成任务管理。数据以 JSON 保存在本机。
@MainActor
@Observable
final class AppStore {
    var servers: [ServerConfig] = []
    var agents: [Agent] = []
    var conversations: [Conversation] = []
    var media = MediaSettings()
    /// 所有助手的长期记忆
    var memories: [MemoryItem] = []
    /// 后台整理（摘要 / 记忆）状态，按对话显示
    var maintenanceStatus: [UUID: String] = [:]

    private(set) var generating: Set<UUID> = []
    @ObservationIgnored var maintenanceRunning: Set<UUID> = []

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init() {
        load()
        if servers.isEmpty && agents.isEmpty {
            seedDefaults()
        }
        let referenced = Set(conversations.flatMap { $0.messages.flatMap { $0.attachments.map(\.fileName) } })
        Task.detached(priority: .background) {
            Storage.removeOrphans(keeping: referenced)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Storage.dataFile) else { return }
        do {
            let decoded = try JSONDecoder().decode(AppData.self, from: data)
            servers = decoded.servers
            agents = decoded.agents
            conversations = decoded.conversations
            media = decoded.media
            memories = decoded.memories ?? []
        } catch {
            // 解析失败时保留一份备份，避免数据被覆盖丢失
            let backup = Storage.baseDirectory.appendingPathComponent("data-backup-\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: backup)
            print("加载数据失败：\(error)")
        }
    }

    /// 延迟保存（合并短时间内的多次修改）
    func save() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = AppData(servers: servers, agents: agents, conversations: conversations, media: media, memories: memories)
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(snapshot)
            try data.write(to: Storage.dataFile, options: .atomic)
        } catch {
            print("保存数据失败：\(error)")
        }
    }

    private func seedDefaults() {
        let server = ServerConfig()
        servers = [server]
        agents = PersonaTemplates.all.map { $0.makeAgent(serverID: nil) }
        saveNow()
    }

    // MARK: - Lookup

    func agent(id: UUID) -> Agent? { agents.first { $0.id == id } }

    func conversation(id: UUID) -> Conversation? { conversations.first { $0.id == id } }

    func conversations(for agentID: UUID) -> [Conversation] {
        conversations.filter { $0.agentID == agentID }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func server(for agent: Agent) -> ServerConfig? {
        if let id = agent.serverID, let server = servers.first(where: { $0.id == id }) {
            return server
        }
        return servers.first
    }

    func effectiveModel(for agent: Agent) -> String {
        if !agent.model.isBlank { return agent.model.trimmed }
        return server(for: agent)?.defaultModel.trimmed ?? ""
    }

    func isGenerating(_ conversationID: UUID) -> Bool { generating.contains(conversationID) }

    func conversationIndex(_ id: UUID) -> Int? { conversations.firstIndex { $0.id == id } }

    // MARK: - Servers

    func upsertServer(_ server: ServerConfig) {
        if let i = servers.firstIndex(where: { $0.id == server.id }) {
            servers[i] = server
        } else {
            servers.append(server)
        }
        save()
    }

    func deleteServer(_ id: UUID) {
        servers.removeAll { $0.id == id }
        for i in agents.indices where agents[i].serverID == id {
            agents[i].serverID = nil
        }
        save()
    }

    // MARK: - Agents

    func upsertAgent(_ agent: Agent) {
        if let i = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[i] = agent
        } else {
            agents.append(agent)
        }
        save()
    }

    func setThinking(_ level: ThinkingLevel, for agentID: UUID) {
        guard let i = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[i].thinking = level
        save()
    }

        func duplicateAgent(_ agent: Agent) {
        var copy = agent
        copy.id = UUID()
        copy.name = agent.name + " 副本"
        copy.createdAt = Date()
        agents.append(copy)
        save()
    }

    func deleteAgent(_ id: UUID) {
        for conversation in conversations where conversation.agentID == id {
            stopGeneration(conversation.id)
            deleteFiles(of: conversation.messages)
        }
        conversations.removeAll { $0.agentID == id }
        memories.removeAll { $0.agentID == id }
        agents.removeAll { $0.id == id }
        save()
    }

    func moveAgents(from source: IndexSet, to destination: Int) {
        agents.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Conversations

    @discardableResult
    func newConversation(for agentID: UUID) -> UUID {
        var conversation = Conversation(agentID: agentID)
        if let agent = agent(id: agentID), !agent.greeting.isBlank {
            conversation.messages.append(ChatMessage(role: .assistant, content: agent.greeting.trimmed))
        }
        conversations.append(conversation)
        save()
        return conversation.id
    }

    func deleteConversation(_ id: UUID) {
        stopGeneration(id)
        if let conversation = conversation(id: id) {
            deleteFiles(of: conversation.messages)
        }
        conversations.removeAll { $0.id == id }
        save()
    }

    func renameConversation(_ id: UUID, to title: String) {
        guard let i = conversationIndex(id), !title.isBlank else { return }
        conversations[i].title = title.trimmed
        save()
    }

    func clearConversation(_ id: UUID) {
        stopGeneration(id)
        guard let i = conversationIndex(id) else { return }
        deleteFiles(of: conversations[i].messages)
        conversations[i].messages.removeAll()
        conversations[i].summary = nil
        conversations[i].summaryCoversUntil = nil
        conversations[i].memoryExtractedUntil = nil
        if let agent = agent(id: conversations[i].agentID), !agent.greeting.isBlank {
            conversations[i].messages.append(ChatMessage(role: .assistant, content: agent.greeting.trimmed))
        }
        conversations[i].updatedAt = Date()
        save()
    }

    func deleteMessage(_ messageID: UUID, in conversationID: UUID) {
        guard let i = conversationIndex(conversationID),
              let m = conversations[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        deleteFiles(of: [conversations[i].messages[m]])
        conversations[i].messages.remove(at: m)
        save()
    }

    func deleteAllConversations() {
        for id in tasks.keys { stopGeneration(id) }
        for conversation in conversations { deleteFiles(of: conversation.messages) }
        conversations.removeAll()
        saveNow()
    }

    private func deleteFiles(of messages: [ChatMessage]) {
        let files = messages.flatMap { $0.attachments.map(\.fileName) }
        guard !files.isEmpty else { return }
        Task.detached(priority: .background) {
            files.forEach(Storage.deleteAttachment)
        }
    }

    // MARK: - Chat

    func send(text: String, attachments: [Attachment], in conversationID: UUID) {
        guard let i = conversationIndex(conversationID) else { return }
        let message = ChatMessage(role: .user, content: text, attachments: attachments)
        conversations[i].messages.append(message)
        conversations[i].updatedAt = Date()

        if conversations[i].title == Conversation.defaultTitle {
            let base = text.trimmed.replacingOccurrences(of: "\n", with: " ")
            if !base.isEmpty {
                conversations[i].title = String(base.prefix(24))
            } else if attachments.contains(where: { $0.kind == .videoFrame }) {
                conversations[i].title = "视频分析"
            } else if !attachments.isEmpty {
                conversations[i].title = "图片分析"
            }
        }
        save()
        generateReply(in: conversationID)
    }

    /// 删除最后一条用户消息之后的回复，并重新生成
    func regenerate(in conversationID: UUID) {
        guard !isGenerating(conversationID), let i = conversationIndex(conversationID) else { return }
        while let last = conversations[i].messages.last, last.role == .assistant {
            conversations[i].messages.removeLast()
        }
        guard conversations[i].messages.last?.role == .user else { return }
        generateReply(in: conversationID)
    }

    func stopGeneration(_ conversationID: UUID) {
        tasks[conversationID]?.cancel()
    }

    private func generateReply(in conversationID: UUID) {
        guard tasks[conversationID] == nil,
              let ci = conversationIndex(conversationID),
              let agent = agent(id: conversations[ci].agentID) else { return }

        guard let server = server(for: agent) else {
            appendError("还没有配置服务器。请在「设置」中添加你的本地 AI 服务器。", to: conversationID)
            return
        }
        let model = effectiveModel(for: agent)
        guard !model.isEmpty else {
            appendError("还没有选择模型。请在助手设置或服务器设置中填写模型名称。", to: conversationID)
            return
        }

        let requestMessages = buildRequestMessages(conversation: conversations[ci], agent: agent)
        let reply = ChatMessage(role: .assistant, content: "", modelName: model)
        conversations[ci].messages.append(reply)
        let replyID = reply.id

        let client = LLMClient(server: server)
        let options = GenerationOptions(model: model, temperature: agent.temperature, maxTokens: agent.maxTokens, thinking: agent.thinking)
        generating.insert(conversationID)

        tasks[conversationID] = Task { [weak self] in
            do {
                for try await event in client.streamChat(messages: requestMessages, options: options) {
                    self?.apply(event, to: replyID, in: conversationID)
                }
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                if !cancelled {
                    self?.markFailed(replyID, in: conversationID, error: LLMError.friendlyDescription(error))
                }
            }
            self?.finishGeneration(conversationID, replyID: replyID)
        }
    }

    private func apply(_ event: StreamEvent, to messageID: UUID, in conversationID: UUID) {
        guard let ci = conversationIndex(conversationID),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else { return }
        switch event {
        case .content(let text): conversations[ci].messages[mi].content += text
        case .reasoning(let text): conversations[ci].messages[mi].reasoning += text
        }
    }

    private func markFailed(_ messageID: UUID, in conversationID: UUID, error: String) {
        guard let ci = conversationIndex(conversationID),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversations[ci].messages[mi].isError = true
        let existing = conversations[ci].messages[mi].content
        conversations[ci].messages[mi].content = existing.isBlank ? error : existing + "\n\n⚠️ " + error
    }

    private func finishGeneration(_ conversationID: UUID, replyID: UUID) {
        tasks[conversationID] = nil
        generating.remove(conversationID)
        if let ci = conversationIndex(conversationID),
           let mi = conversations[ci].messages.firstIndex(where: { $0.id == replyID }) {
            let message = conversations[ci].messages[mi]
            let succeeded = !message.isError && !message.content.isBlank
            if message.content.isBlank && message.reasoning.isBlank && !message.isError {
                conversations[ci].messages[mi].content = "（已停止）"
            }
            conversations[ci].updatedAt = Date()
            if succeeded {
                // 更新滚动摘要、自动提取长期记忆（按需，在后台进行）
                scheduleMaintenance(conversationID)
            }
        }
        save()
    }

    private func appendError(_ text: String, to conversationID: UUID) {
        guard let ci = conversationIndex(conversationID) else { return }
        conversations[ci].messages.append(ChatMessage(role: .assistant, content: text, isError: true))
        save()
    }

    /// 组装发送给模型的消息：系统提示词（人格设定）+ 历史上下文 + 图片/视频帧
    private func buildRequestMessages(conversation: Conversation, agent: Agent) -> [RequestMessage] {
        let allHistory = conversation.messages.filter { message in
            !message.isError && message.role != .system && !(message.role == .assistant && message.content.isBlank)
        }
        var history = allHistory
        var summaryText: String?

        if agent.contextMessageLimit > 0 {
            let limit = agent.contextMessageLimit
            if agent.rollingSummary {
                // 已被摘要覆盖的早期消息不再逐条发送，改为发送摘要
                if let until = conversation.summaryCoversUntil {
                    history = history.filter { $0.createdAt > until }
                }
                if let summary = conversation.summary, !summary.isBlank {
                    summaryText = summary.trimmed
                }
                // 摘要还没来得及更新时的上限
                let cap = limit + Self.summaryBatch * 2
                if history.count > cap { history = Array(history.suffix(cap)) }
            } else if history.count > limit {
                history = Array(history.suffix(limit))
            }
        }

        var systemParts: [String] = []
        let persona = agent.systemPrompt.trimmed
        if !persona.isEmpty { systemParts.append(persona) }

        if agent.memoryEnabled {
            let items = memories(for: agent.id)
            if !items.isEmpty {
                systemParts.append(
                    "【长期记忆】\n以下是你在以往的对话中了解到的信息，请在合适的时候自然地运用，不要生硬地复述：\n"
                        + items.map { "- " + $0.text }.joined(separator: "\n")
                )
            }
        }
        if let summaryText {
            systemParts.append("【本次对话早期内容的摘要】\n\(summaryText)")
        }

        // 部分模型模板要求第一条非系统消息必须来自用户
        let startsAtBeginning = history.first?.id == allHistory.first?.id
        var openings: [String] = []
        while let first = history.first, first.role == .assistant {
            openings.append(ThinkParser.split(first.content).answer)
            history.removeFirst()
        }
        if !openings.isEmpty && startsAtBeginning {
            // 开场白并入系统提示词
            systemParts.append("（对话开始时你已经对用户说过：「\(openings.joined(separator: "\n"))」）")
        }
        let system = systemParts.joined(separator: "\n\n")

        var result: [RequestMessage] = []
        if !system.isEmpty {
            result.append(RequestMessage(role: .system, text: system))
        }

        let lastWithMedia = history.lastIndex { $0.role == .user && !$0.attachments.isEmpty }
        for (index, message) in history.enumerated() {
            var text = message.role == .assistant ? ThinkParser.split(message.content).answer : message.content
            var files: [String] = []
            if !message.attachments.isEmpty {
                if media.sendHistoryImages || index == lastWithMedia {
                    files = message.attachments.map(\.fileName)
                    text = Self.describeAttachments(message.attachments) + text
                } else {
                    text = "[此前发送过 \(message.attachments.count) 张图片/视频帧]\n" + text
                }
            }
            result.append(RequestMessage(role: message.role, text: text, imageFiles: files))
        }
        return result
    }

    /// 为视频帧补充时间信息，帮助模型按时间顺序理解画面
    nonisolated static func describeAttachments(_ attachments: [Attachment]) -> String {
        let frames = attachments.filter { $0.kind == .videoFrame }
        guard !frames.isEmpty else { return "" }
        let imageCount = attachments.count - frames.count

        var groups: [(UUID?, [Attachment])] = []
        for frame in frames {
            if let i = groups.firstIndex(where: { $0.0 == frame.videoGroupID }) {
                groups[i].1.append(frame)
            } else {
                groups.append((frame.videoGroupID, [frame]))
            }
        }

        var lines: [String] = []
        if imageCount > 0 {
            lines.append("前 \(imageCount) 张是图片。")
        }
        for (index, group) in groups.enumerated() {
            let times = group.1.compactMap(\.timestamp).map(Format.timestamp).joined(separator: "、")
            let duration = group.1.first?.videoDuration.map { "，时长 \(Format.duration($0))" } ?? ""
            let label = groups.count > 1 ? "视频\(index + 1)" : "视频"
            lines.append("【\(label)\(duration)】以下 \(group.1.count) 张图片是按时间顺序从视频中抽取的画面，时间点：\(times)。")
        }
        return lines.joined(separator: "\n") + "\n\n"
    }
}
