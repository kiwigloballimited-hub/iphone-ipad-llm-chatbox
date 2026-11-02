import Foundation

/// 长期记忆（跨会话）与滚动摘要（单个会话内的早期内容压缩）
extension AppStore {
    /// 未被摘要覆盖的消息超过「上下文条数 + 这个数」时，触发一次摘要
    static let summaryBatch = 6
    /// 自动记忆：每累计这么多条新的用户消息，提取一次
    static let autoMemoryUserMessages = 3

    // MARK: - 记忆本

    func memories(for agentID: UUID) -> [MemoryItem] {
        memories.filter { $0.agentID == agentID }.sorted { $0.createdAt < $1.createdAt }
    }

    func addMemory(_ text: String, to agentID: UUID, source: MemoryItem.Source = .manual, conversationID: UUID? = nil) {
        let value = text.trimmed
        guard !value.isEmpty,
              !memories.contains(where: { $0.agentID == agentID && $0.text == value }) else { return }
        memories.append(MemoryItem(agentID: agentID, text: value, source: source, conversationID: conversationID))
        save()
    }

    func updateMemory(_ id: UUID, text: String) {
        guard let i = memories.firstIndex(where: { $0.id == id }), !text.isBlank else { return }
        memories[i].text = text.trimmed
        save()
    }

    func deleteMemory(_ id: UUID) {
        memories.removeAll { $0.id == id }
        save()
    }

    func clearMemories(for agentID: UUID) {
        memories.removeAll { $0.agentID == agentID }
        save()
    }

    // MARK: - 手动提取记忆

    /// 从整个对话中提取候选记忆，交给用户确认
    func extractMemoryCandidates(from conversationID: UUID) async throws -> [String] {
        guard let conversation = conversation(id: conversationID),
              let agent = agent(id: conversation.agentID) else { return [] }
        let messages = Self.usableMessages(conversation.messages)
        guard !messages.isEmpty else { return [] }
        return try await requestMemories(agent: agent, messages: messages)
    }

    /// 保存用户确认后的记忆
    func acceptMemories(_ texts: [String], from conversationID: UUID) {
        guard let conversation = conversation(id: conversationID) else { return }
        for text in texts {
            addMemory(text, to: conversation.agentID, source: .extracted, conversationID: conversationID)
        }
        if let i = conversationIndex(conversationID),
           let last = Self.usableMessages(conversations[i].messages).last {
            conversations[i].memoryExtractedUntil = last.createdAt
        }
        save()
    }

    // MARK: - 回复完成后的后台整理

    func scheduleMaintenance(_ conversationID: UUID) {
        guard !maintenanceRunning.contains(conversationID) else { return }
        maintenanceRunning.insert(conversationID)
        Task { [weak self] in
            await self?.summarizeIfNeeded(conversationID)
            await self?.autoExtractIfNeeded(conversationID)
            self?.maintenanceRunning.remove(conversationID)
            self?.maintenanceStatus[conversationID] = nil
        }
    }

    func clearSummary(_ conversationID: UUID) {
        guard let i = conversationIndex(conversationID) else { return }
        conversations[i].summary = nil
        conversations[i].summaryCoversUntil = nil
        save()
    }

    /// 滚动摘要：把超出上下文窗口的早期消息压缩进摘要
    private func summarizeIfNeeded(_ conversationID: UUID) async {
        guard let conversation = conversation(id: conversationID),
              let agent = agent(id: conversation.agentID),
              agent.rollingSummary, agent.contextMessageLimit > 0 else { return }

        let limit = agent.contextMessageLimit
        let uncovered = Self.usableMessages(conversation.messages).filter { message in
            guard let until = conversation.summaryCoversUntil else { return true }
            return message.createdAt > until
        }
        guard uncovered.count > limit + Self.summaryBatch else { return }

        let chunk = Array(uncovered.dropLast(limit))
        guard let lastCovered = chunk.last, case let (client, options)? = utilityClient(for: agent) else { return }

        maintenanceStatus[conversationID] = "正在整理早期对话摘要…"
        var prompt = "请把下面的对话内容压缩成一段简洁的摘要，供之后继续对话时参考。\n要求：保留关键事实、用户的需求和偏好、已经得出的结论或决定、尚未完成的事项；用第三人称叙述（「用户」「\(agent.name)」）；不超过 400 字；只输出摘要本身。\n\n"
        if let previous = conversation.summary, !previous.isBlank {
            prompt += "【已有摘要】（请与下面的新内容合并成一份完整的摘要）\n\(previous)\n\n"
        }
        prompt += "【新的对话内容】\n" + Self.transcript(chunk, agentName: agent.name, maxCharacters: 16000)

        do {
            let summary = try await client.complete(
                messages: [
                    RequestMessage(role: .system, text: "你是一个擅长归纳总结的助手。"),
                    RequestMessage(role: .user, text: prompt),
                ],
                options: options
            )
            guard !summary.isEmpty, let i = conversationIndex(conversationID) else { return }
            conversations[i].summary = summary
            conversations[i].summaryCoversUntil = lastCovered.createdAt
            save()
        } catch {
            print("生成摘要失败：\(error)")
        }
    }

    /// 自动记忆：累计足够多的新消息后，提取并直接加入记忆本
    private func autoExtractIfNeeded(_ conversationID: UUID) async {
        guard let conversation = conversation(id: conversationID),
              let agent = agent(id: conversation.agentID),
              agent.memoryEnabled, agent.autoMemory else { return }

        let pending = Self.usableMessages(conversation.messages).filter { message in
            guard let until = conversation.memoryExtractedUntil else { return true }
            return message.createdAt > until
        }
        guard pending.filter({ $0.role == .user }).count >= Self.autoMemoryUserMessages,
              let last = pending.last else { return }

        maintenanceStatus[conversationID] = "正在整理长期记忆…"
        do {
            let items = try await requestMemories(agent: agent, messages: pending)
            for text in items {
                addMemory(text, to: agent.id, source: .auto, conversationID: conversationID)
            }
            if let i = conversationIndex(conversationID) {
                conversations[i].memoryExtractedUntil = last.createdAt
            }
            save()
        } catch {
            print("自动提取记忆失败：\(error)")
        }
    }

    // MARK: - Helpers

    private func requestMemories(agent: Agent, messages: [ChatMessage]) async throws -> [String] {
        guard case let (client, options)? = utilityClient(for: agent) else {
            throw LLMError.server("还没有配置服务器或模型。")
        }
        let existing = memories(for: agent.id)
        let existingText = existing.isEmpty ? "（暂无）" : existing.map { "- " + $0.text }.joined(separator: "\n")

        let prompt = """
        下面是用户与 AI 助手「\(agent.name)」的一段对话。请从中提取值得长期记住、以后的对话中也用得上的信息，例如：用户的个人情况、喜好与习惯、正在进行的项目或作品、重要的事实、约定或目标。

        要求：
        - 每条记忆单独一行，以「- 」开头；简洁、完整，单独看也能理解；用「用户」指代用户。
        - 只提取新的信息，不要重复「已有记忆」中已经包含的内容。
        - 不要记录寒暄、一次性的临时问题，也不要记录助手回答的具体内容。
        - 如果没有值得记住的新信息，只输出：无

        【已有记忆】
        \(existingText)

        【对话】
        \(Self.transcript(messages, agentName: agent.name, maxCharacters: 12000))
        """

        let reply = try await client.complete(
            messages: [
                RequestMessage(role: .system, text: "你是一个负责整理长期记忆的助手，只输出记忆列表。"),
                RequestMessage(role: .user, text: prompt),
            ],
            options: options
        )
        let existingSet = Set(existing.map(\.text))
        return Self.parseMemoryLines(reply).filter { !existingSet.contains($0) }
    }

    /// 后台任务使用的客户端：同一个服务器和模型，关闭思考、低温度，速度更快、结果更稳定
    private func utilityClient(for agent: Agent) -> (LLMClient, GenerationOptions)? {
        guard let server = server(for: agent) else { return nil }
        let model = effectiveModel(for: agent)
        guard !model.isEmpty else { return nil }
        return (LLMClient(server: server), GenerationOptions(model: model, temperature: 0.3, maxTokens: 0, thinking: .off))
    }

    nonisolated static func usableMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.filter { message in
            !message.isError && message.role != .system
                && !(message.content.isBlank && message.attachments.isEmpty)
        }
    }

    /// 把消息整理成纯文本对话记录（保留最后的 maxCharacters 个字符左右）
    nonisolated static func transcript(_ messages: [ChatMessage], agentName: String, maxCharacters: Int) -> String {
        var lines: [String] = []
        for message in messages {
            var text = message.role == .assistant ? ThinkParser.split(message.content).answer : message.content
            text = text.trimmed
            if text.count > 1500 { text = String(text.prefix(1500)) + "…" }
            if !message.attachments.isEmpty {
                text = "[附带 \(message.attachments.count) 张图片/视频帧] " + text
            }
            guard !text.isEmpty else { continue }
            lines.append("\(message.role == .user ? "用户" : agentName)：\(text)")
        }
        var kept: [String] = []
        var total = 0
        for line in lines.reversed() {
            if total + line.count > maxCharacters && !kept.isEmpty { break }
            kept.append(line)
            total += line.count
        }
        return kept.reversed().joined(separator: "\n\n")
    }

    /// 解析模型输出的记忆列表
    nonisolated static func parseMemoryLines(_ text: String) -> [String] {
        var result: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmed
            guard !line.isEmpty else { continue }
            for prefix in ["- ", "-", "• ", "•", "* ", "·"] where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
                break
            }
            if let range = line.range(of: #"^\d+[\.、\)）]\s*"#, options: .regularExpression) {
                line.removeSubrange(range)
            }
            line = line.trimmed
            if line.isEmpty || line == "无" || line.hasPrefix("无新") || line.hasPrefix("没有") { continue }
            if line.hasSuffix("：") || line.hasSuffix(":") { continue }
            if !result.contains(line) { result.append(line) }
        }
        return result
    }
}
