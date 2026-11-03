import Foundation
import Observation
import SwiftUI

struct AnnotationRequest: Equatable {
    let conversationID: UUID
    let fileName: String
}

/// 全局状态：服务器、助手、对话、媒体设置，以及生成任务管理。数据以 JSON 保存在本机。
@MainActor
@Observable
final class AppStore {
    /// 整个 App（包括 Siri / 快捷指令）共用同一份数据
    static let shared = AppStore()

    var servers: [ServerConfig] = []
    var agents: [Agent] = []
    var conversations: [Conversation] = []
    var media = MediaSettings()
    /// 所有助手的长期记忆
    var memories: [MemoryItem] = []
    /// 用户自定义的模型价格（美元 / 百万 token）
    var customPrices: [String: ModelPrice] = [:]
    /// 自动检测到的上下文窗口（键：服务器ID|模型名）
    var contextWindows: [String: Int] = [:]
    @ObservationIgnored var contextDetectionAttempted: Set<String> = []
    /// 后台整理（摘要 / 记忆）状态，按对话显示
    var maintenanceStatus: [UUID: String] = [:]

    private(set) var generating: Set<UUID> = []
    @ObservationIgnored var maintenanceRunning: Set<UUID> = []
    /// 每个对话的内置浏览器（不保存到磁盘）
    var browserSessions: [UUID: BrowserSession] = [:]
    /// 新对话的预填草稿（例如「编辑并分叉」）
    @ObservationIgnored var pendingDrafts: [UUID: Draft] = [:]
    /// 请求界面切换到的对话
    var navigationTarget: UUID?
    /// 请求在某个对话中打开语音输入（操作按钮 / Siri / 小组件）
    var voiceRequest: UUID?
    /// 请求用 Apple Pencil 标注对话里的某张图片
    var annotationRequest: AnnotationRequest?
    /// 断线重试状态（按对话显示）
    var retryStatus: [UUID: String] = [:]
    /// 等待用户确认的操作说明（按对话）
    var pendingConfirmations: [UUID: String] = [:]
    @ObservationIgnored var confirmationContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    @ObservationIgnored var tasks: [UUID: Task<Void, Never>] = [:]
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
            customPrices = decoded.customPrices ?? [:]
            contextWindows = decoded.contextWindows ?? [:]
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
        let snapshot = AppData(servers: servers, agents: agents, conversations: conversations, media: media, memories: memories, customPrices: customPrices, contextWindows: contextWindows)
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
        refreshAppShortcuts()
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
        refreshAppShortcuts()
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
        browserSessions[id] = nil
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
            } else if let document = attachments.first(where: { $0.kind == .document }) {
                conversations[i].title = String(("文档：" + (document.displayName ?? "文档")).prefix(24))
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

    /// 从断点继续生成（上一条回复因网络中断而失败时）
    func continueReply(in conversationID: UUID) {
        guard !isGenerating(conversationID),
              let ci = conversationIndex(conversationID),
              let last = conversations[ci].messages.last,
              last.role == .assistant, last.isError, last.errorText != nil,
              !ThinkParser.split(last.content).answer.isBlank,
              let agent = agent(id: conversations[ci].agentID), !agent.browserEnabled else {
            regenerate(in: conversationID)
            return
        }
        generateReply(in: conversationID, continuing: last.id)
    }

    func stopGeneration(_ conversationID: UUID) {
        tasks[conversationID]?.cancel()
        resolveConfirmation(conversationID, approved: false)
    }

    private func generateReply(in conversationID: UUID, continuing continueID: UUID? = nil) {
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

        // 注意：要在清除失败标记之前组装，失败的消息不会进入历史
        let requestMessages = buildRequestMessages(conversation: conversations[ci], agent: agent)
        var initialMessages = requestMessages
        let replyID: UUID
        if let continueID, let mi = conversations[ci].messages.firstIndex(where: { $0.id == continueID }) {
            // 从断点继续：沿用原来的消息，请模型接着写
            let partial = ThinkParser.split(conversations[ci].messages[mi].content).answer
            conversations[ci].messages[mi].isError = false
            conversations[ci].messages[mi].errorText = nil
            initialMessages = RetryPolicy.continuation(base: requestMessages, partial: partial)
            replyID = continueID
        } else {
            let reply = ChatMessage(role: .assistant, content: "", modelName: model)
            conversations[ci].messages.append(reply)
            replyID = reply.id
        }

        let client = LLMClient(server: server)
        let options = GenerationOptions(model: model, temperature: agent.temperature, maxTokens: agent.maxTokens, thinking: agent.thinking, penalties: agent.penalties)
        generating.insert(conversationID)
        if media.liveActivities {
            LiveActivityManager.shared.start(conversationID: conversationID, agent: agent, title: conversations[ci].title)
        }

        if agent.browserEnabled {
            // 浏览器助手：工具调用循环
            tasks[conversationID] = Task { [weak self] in
                let activity = BackgroundActivity.begin("浏览器助手")
                await self?.runAgentReply(
                    conversationID: conversationID,
                    replyID: replyID,
                    client: client,
                    options: options,
                    requestMessages: requestMessages
                )
                self?.finishGeneration(conversationID, replyID: replyID)
                activity.end()
            }
            return
        }

        tasks[conversationID] = Task { [weak self] in
            let activity = BackgroundActivity.begin("生成回复")
            await self?.streamWithRetry(
                conversationID: conversationID,
                replyID: replyID,
                client: client,
                options: options,
                baseMessages: requestMessages,
                initialMessages: initialMessages
            )
            self?.finishGeneration(conversationID, replyID: replyID)
            activity.end()
        }
    }

    /// 流式生成；遇到网络中断等临时错误时自动重试，已生成的部分从断点续写
    private func streamWithRetry(
        conversationID: UUID,
        replyID: UUID,
        client: LLMClient,
        options: GenerationOptions,
        baseMessages: [RequestMessage],
        initialMessages: [RequestMessage]
    ) async {
        var messages = initialMessages
        var attempt = 0
        while true {
            // 记录这次请求开始前的内容，服务器没有返回用量时用来估算
            let before = messageText(replyID, in: conversationID)
            var receivedUsage = false
            do {
                for try await event in client.streamChat(messages: messages, options: options) {
                    if retryStatus[conversationID] != nil { retryStatus[conversationID] = nil }
                    if case .usage = event { receivedUsage = true }
                    apply(event, to: replyID, in: conversationID)
                }
                retryStatus[conversationID] = nil
                if !receivedUsage {
                    let after = messageText(replyID, in: conversationID)
                    let output = String(after.content.dropFirst(before.content.count)) + String(after.reasoning.dropFirst(before.reasoning.count))
                    apply(.usage(TokenEstimator.estimateUsage(messages: messages, output: output)), to: replyID, in: conversationID)
                }
                return
            } catch {
                if RetryPolicy.isCancellation(error) {
                    retryStatus[conversationID] = nil
                    return
                }
                guard await waitBeforeRetry(after: error, attempt: &attempt, conversationID: conversationID) else {
                    markFailed(replyID, in: conversationID, error: LLMError.friendlyDescription(error))
                    return
                }
                messages = prepareRetry(replyID: replyID, conversationID: conversationID, base: baseMessages)
            }
        }
    }

    func messageText(_ messageID: UUID, in conversationID: UUID) -> (content: String, reasoning: String) {
        guard let ci = conversationIndex(conversationID),
              let message = conversations[ci].messages.first(where: { $0.id == messageID }) else { return ("", "") }
        return (message.content, message.reasoning)
    }

    /// 判断是否应该重试；需要时显示状态并等待。返回 false 表示不再重试。
    func waitBeforeRetry(after error: Error, attempt: inout Int, conversationID: UUID) async -> Bool {
        guard media.autoRetry, attempt < media.retryLimit, RetryPolicy.isTransient(error) else {
            retryStatus[conversationID] = nil
            return false
        }
        attempt += 1
        let seconds = RetryPolicy.delaySeconds(forAttempt: attempt)
        retryStatus[conversationID] = "连接中断，\(seconds) 秒后重试（第 \(attempt)/\(media.retryLimit) 次）…"
        LiveActivityManager.shared.update(conversationID, phase: .retrying, detail: "第 \(attempt) 次重试", force: true)
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        } catch {
            retryStatus[conversationID] = nil
            return false
        }
        if Task.isCancelled {
            retryStatus[conversationID] = nil
            return false
        }
        retryStatus[conversationID] = "正在重新连接…"
        return true
    }

    /// 重试前整理消息：还没有正文就从头生成；已有正文则从断点续写
    private func prepareRetry(replyID: UUID, conversationID: UUID, base: [RequestMessage]) -> [RequestMessage] {
        guard let ci = conversationIndex(conversationID),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == replyID }) else { return base }
        let answer = ThinkParser.split(conversations[ci].messages[mi].content).answer
        if answer.isBlank {
            conversations[ci].messages[mi].content = ""
            conversations[ci].messages[mi].reasoning = ""
            return base
        }
        return RetryPolicy.continuation(base: base, partial: answer)
    }

    func apply(_ event: StreamEvent, to messageID: UUID, in conversationID: UUID) {
        guard let ci = conversationIndex(conversationID),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else { return }
        switch event {
        case .content(let text):
            conversations[ci].messages[mi].content += text
            if LiveActivityManager.shared.shouldUpdate(conversationID) {
                let message = conversations[ci].messages[mi]
                LiveActivityManager.shared.update(
                    conversationID,
                    phase: .writing,
                    detail: ThinkParser.split(message.content).answer,
                    tokens: TokenEstimator.estimate(message.content + message.reasoning)
                )
            }
        case .reasoning(let text):
            conversations[ci].messages[mi].reasoning += text
            if LiveActivityManager.shared.shouldUpdate(conversationID) {
                LiveActivityManager.shared.update(conversationID, phase: .thinking)
            }
        case .usage(let usage):
            var current = conversations[ci].messages[mi].usage ?? TokenUsage()
            current.add(usage)
            conversations[ci].messages[mi].usage = current
        }
    }

    func markFailed(_ messageID: UUID, in conversationID: UUID, error: String) {
        guard let ci = conversationIndex(conversationID),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else { return }
        // 保留已生成的内容，错误原因单独保存，便于「从断点继续」
        conversations[ci].messages[mi].isError = true
        conversations[ci].messages[mi].errorText = error
    }

    private func finishGeneration(_ conversationID: UUID, replyID: UUID) {
        tasks[conversationID] = nil
        generating.remove(conversationID)
        retryStatus[conversationID] = nil
        if let ci = conversationIndex(conversationID),
           let mi = conversations[ci].messages.firstIndex(where: { $0.id == replyID }) {
            let message = conversations[ci].messages[mi]
            let succeeded = !message.isError && !message.content.isBlank
            LiveActivityManager.shared.end(
                conversationID,
                success: succeeded,
                preview: succeeded ? ThinkParser.split(message.content).answer : (message.errorText ?? "已停止"),
                tokens: message.usage?.outputTokens ?? TokenEstimator.estimate(message.content + message.reasoning)
            )
            if message.content.isBlank && message.reasoning.isBlank && !message.isError {
                conversations[ci].messages[mi].content = "（已停止）"
            }
            conversations[ci].updatedAt = Date()
            if succeeded {
                // 更新滚动摘要、自动提取长期记忆（按需，在后台进行）
                scheduleMaintenance(conversationID)
                // 模型已加载，再检测一次上下文窗口（Ollama 只有加载后才能查到实际值）
                if let agent = agent(id: conversations[ci].agentID) {
                    Task { [weak self] in await self?.detectContextWindowIfNeeded(for: agent, force: true) }
                }
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
    func buildRequestMessages(conversation: Conversation, agent: Agent) -> [RequestMessage] {
        let validMessages = conversation.messages.filter { message in
            !message.isError && message.role != .system && !(message.role == .assistant && message.content.isBlank)
                && !message.isExcluded
        }
        // 上下文起点之前的消息不发送（置顶的消息稍后单独加入）
        let allHistory = validMessages.filter { message in
            guard let start = conversation.contextStartsAt else { return true }
            return message.createdAt >= start
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

        // 部分模型模板要求第一条非系统消息必须来自用户
        let startsAtBeginning = history.first?.id == validMessages.first?.id
        var openings: [String] = []
        var openingIDs = Set<UUID>()
        while let first = history.first, first.role == .assistant {
            if startsAtBeginning {
                openings.append(ThinkParser.split(first.content).answer)
                openingIDs.insert(first.id)
            }
            history.removeFirst()
        }

        // 不在窗口里的置顶消息，放进系统提示词
        let windowIDs = Set(history.map(\.id)).union(openingIDs)
        let pinnedOutside = validMessages.filter { $0.isPinned && !windowIDs.contains($0.id) }

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
        if !pinnedOutside.isEmpty {
            let lines = pinnedOutside.map { message -> String in
                let speaker = message.role == .user ? "用户" : "你（\(agent.name)）"
                var text = message.role == .assistant ? ThinkParser.split(message.content).answer : message.content
                let visualCount = message.attachments.filter(\.isVisual).count
                if visualCount > 0 {
                    text = "[附带 \(visualCount) 张图片/视频帧] " + text
                }
                let documents = message.attachments.filter { $0.kind == .document }
                if !documents.isEmpty {
                    text = Self.documentContext(documents) + text
                }
                return "\(speaker)：\(text.trimmed)"
            }
            systemParts.append("【置顶的重要内容】\n以下是用户置顶的早期对话内容，请始终参考：\n\n" + lines.joined(separator: "\n\n"))
        }
        if let summaryText {
            systemParts.append("【本次对话早期内容的摘要】\n\(summaryText)")
        }

        if !openings.isEmpty {
            // 开场白并入系统提示词
            systemParts.append("（对话开始时你已经对用户说过：「\(openings.joined(separator: "\n"))」）")
        }
        let system = systemParts.joined(separator: "\n\n")

        var result: [RequestMessage] = []
        if !system.isEmpty {
            result.append(RequestMessage(role: .system, text: system))
        }

        let lastWithMedia = history.lastIndex { $0.role == .user && $0.attachments.contains(where: \.isVisual) }
        for (index, message) in history.enumerated() {
            var text = message.role == .assistant ? ThinkParser.split(message.content).answer : message.content
            var files: [String] = []
            // 文档：提取的文字作为上下文（始终发送；不需要时可以对这条消息选择「不发送给模型」）
            let documents = message.attachments.filter { $0.kind == .document }
            if !documents.isEmpty {
                text = Self.documentContext(documents) + text
            }
            let visual = message.attachments.filter(\.isVisual)
            if !visual.isEmpty {
                if media.sendHistoryImages || index == lastWithMedia {
                    files = visual.map(\.fileName)
                    text = Self.describeAttachments(visual) + text
                } else {
                    text = "[此前发送过 \(visual.count) 张图片/视频帧]\n" + text
                }
            }
            result.append(RequestMessage(role: message.role, text: text, imageFiles: files))
        }
        return result
    }

    /// 单个文档发送给模型的最多字符数
    nonisolated static let documentCharacterLimit = 40_000

    /// 文档内容（作为文字上下文）
    nonisolated static func documentContext(_ documents: [Attachment]) -> String {
        var parts: [String] = []
        for document in documents {
            let content = Storage.loadText(document.fileName) ?? ""
            let limited = content.count > documentCharacterLimit
                ? String(content.prefix(documentCharacterLimit)) + "\n……（文档较长，后面的内容已省略）"
                : content
            let pages = document.pageCount.map { "，共 \($0) 页" } ?? ""
            parts.append("【附件文档：\(document.displayName ?? "文档")\(pages)】\n\(limited)\n【文档结束】")
        }
        return parts.joined(separator: "\n\n") + "\n\n"
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
