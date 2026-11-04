import Foundation

/// 工具调用循环（浏览器助手）
extension AppStore {
    /// 一次回复中最多执行的工具轮数
    static let maxAgentSteps = 25

    func browser(for conversationID: UUID) -> BrowserSession {
        if let existing = browserSessions[conversationID] { return existing }
        let session = BrowserSession()
        browserSessions[conversationID] = session
        return session
    }

    // MARK: - 用户确认

    /// 暂停并等待用户确认（在聊天界面弹出）
    func requestConfirmation(_ message: String, in conversationID: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            confirmationContinuations.removeValue(forKey: conversationID)?.resume(returning: false)
            confirmationContinuations[conversationID] = continuation
            pendingConfirmations[conversationID] = message
        }
    }

    func resolveConfirmation(_ conversationID: UUID, approved: Bool) {
        pendingConfirmations[conversationID] = nil
        confirmationContinuations.removeValue(forKey: conversationID)?.resume(returning: approved)
    }

    // MARK: - Agent loop

    func runAgentReply(
        conversationID: UUID,
        replyID: UUID,
        client: LLMClient,
        options: GenerationOptions,
        requestMessages: [RequestMessage]
    ) async {
        // 系统提示词 = 人格设定 / 记忆 + 浏览器使用说明（整个循环中保持不变）
        var history = requestMessages
        var system = BrowserTools.systemPrompt
        if let first = history.first, first.role == .system {
            system = first.text + "\n\n" + BrowserTools.systemPrompt
            history.removeFirst()
        }
        var entries: [AgentEntry] = [.system(system)]
        entries.append(contentsOf: history.map { AgentEntry.message($0) })

        let browser = browser(for: conversationID)
        let searchEngine = media.searchEngine
        let compactOldResults = client.server.apiType != .anthropic

        do {
            for step in 0..<Self.maxAgentSteps {
                var finished: AssistantTurn?
                let requestEntries = compactOldResults ? Self.compacted(entries) : entries
                // 断线时只重做这一轮：先记下这一轮开始前的内容，重试前恢复
                let saved = savedText(replyID, in: conversationID)
                var attempt = 0

                while true {
                    var needsSeparator = step > 0
                    do {
                        for try await event in client.streamTurn(entries: requestEntries, tools: BrowserTools.specs, options: options) {
                            if retryStatus[conversationID] != nil { retryStatus[conversationID] = nil }
                            switch event {
                            case .content(let text):
                                if needsSeparator {
                                    appendSeparator(to: replyID, in: conversationID)
                                    needsSeparator = false
                                }
                                apply(.content(text), to: replyID, in: conversationID)
                            case .reasoning(let text):
                                apply(.reasoning(text), to: replyID, in: conversationID)
                            case .finished(let turn):
                                finished = turn
                            }
                        }
                        break
                    } catch {
                        if RetryPolicy.isCancellation(error) { throw error }
                        guard await waitBeforeRetry(after: error, attempt: &attempt, conversationID: conversationID) else {
                            throw error
                        }
                        restoreText(saved, to: replyID, in: conversationID)
                        finished = nil
                    }
                }

                guard let turn = finished else { break }
                // 记录这一轮的用量（服务器没有返回时估算）
                if let usage = turn.usage {
                    apply(.usage(usage), to: replyID, in: conversationID)
                } else {
                    let output = turn.text + turn.reasoning + turn.toolCalls.map(\.rawArguments).joined()
                    let estimate = TokenUsage(
                        inputTokens: TokenEstimator.estimate(entries: requestEntries),
                        outputTokens: TokenEstimator.estimate(output),
                        estimated: true
                    )
                    apply(.usage(estimate), to: replyID, in: conversationID)
                }
                if turn.stopReason == "refusal" {
                    appendNote(String(localized: "（模型拒绝了这个请求。）"), to: replyID, in: conversationID)
                    break
                }
                if turn.toolCalls.isEmpty { break }
                if turn.stopReason == "max_tokens" {
                    appendNote(String(localized: "（回复长度达到上限，工具调用没有执行。可以在助手设置中调大「最大回复长度」。）"), to: replyID, in: conversationID)
                    break
                }

                entries.append(.assistantTurn(turn))
                var results: [ToolResult] = []
                for call in turn.toolCalls {
                    try Task.checkCancellation()
                    let info = BrowserTools.stepInfo(call)
                    let stepID = addStep(AgentStep(icon: info.icon, title: info.title), to: replyID, in: conversationID)
                    let outcome = await BrowserTools.execute(call, browser: browser, searchEngine: searchEngine) { [weak self] message in
                        await self?.requestConfirmation(message, in: conversationID) ?? false
                    }
                    updateStep(stepID, status: outcome.status, title: outcome.title, in: replyID, conversationID: conversationID)
                    results.append(ToolResult(callID: call.id, name: call.name, content: outcome.result, isError: outcome.isError))
                }
                // 同一轮的所有工具结果放在同一条消息里返回
                entries.append(.toolResults(results))

                if step == Self.maxAgentSteps - 1 {
                    appendNote(String(localized: "（已达到单次回复最多 \(Self.maxAgentSteps) 轮操作的上限。可以说「继续」让它接着做。）"), to: replyID, in: conversationID)
                }
            }
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            if !cancelled {
                markFailed(replyID, in: conversationID, error: LLMError.friendlyDescription(error))
            }
        }
        // 正在执行中的步骤（例如被中途停止）标记为失败
        finishRunningSteps(replyID, in: conversationID)
    }

    /// 本地模型上下文有限：较早的网页内容只保留开头（Anthropic 要求历史不变，所以不压缩）
    private static func compacted(_ entries: [AgentEntry]) -> [AgentEntry] {
        let resultIndices = entries.indices.filter {
            if case .toolResults = entries[$0] { return true }
            return false
        }
        let keep = Set(resultIndices.suffix(2))
        return entries.enumerated().map { (index, entry) -> AgentEntry in
            guard case .toolResults(let results) = entry, !keep.contains(index) else { return entry }
            return .toolResults(results.map { result -> ToolResult in
                guard result.content.count > 400 else { return result }
                return ToolResult(
                    callID: result.callID,
                    name: result.name,
                    content: String(result.content.prefix(400)) + String(localized: "…（较早的页面内容已省略）"),
                    isError: result.isError
                )
            })
        }
    }

    // MARK: - Message helpers

    private func messageIndices(_ messageID: UUID, _ conversationID: UUID) -> (Int, Int)? {
        guard let ci = conversationIndex(conversationID),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        return (ci, mi)
    }

    private func savedText(_ messageID: UUID, in conversationID: UUID) -> (content: String, reasoning: String) {
        guard case let (ci, mi)? = messageIndices(messageID, conversationID) else { return ("", "") }
        return (conversations[ci].messages[mi].content, conversations[ci].messages[mi].reasoning)
    }

    private func restoreText(_ saved: (content: String, reasoning: String), to messageID: UUID, in conversationID: UUID) {
        guard case let (ci, mi)? = messageIndices(messageID, conversationID) else { return }
        conversations[ci].messages[mi].content = saved.content
        conversations[ci].messages[mi].reasoning = saved.reasoning
    }

    private func appendSeparator(to messageID: UUID, in conversationID: UUID) {
        guard case let (ci, mi)? = messageIndices(messageID, conversationID) else { return }
        let content = conversations[ci].messages[mi].content
        if !content.isEmpty && !content.hasSuffix("\n\n") {
            conversations[ci].messages[mi].content += content.hasSuffix("\n") ? "\n" : "\n\n"
        }
    }

    private func appendNote(_ note: String, to messageID: UUID, in conversationID: UUID) {
        appendSeparator(to: messageID, in: conversationID)
        apply(.content(note), to: messageID, in: conversationID)
    }

    private func addStep(_ step: AgentStep, to messageID: UUID, in conversationID: UUID) -> UUID {
        guard case let (ci, mi)? = messageIndices(messageID, conversationID) else { return step.id }
        conversations[ci].messages[mi].steps = (conversations[ci].messages[mi].steps ?? []) + [step]
        LiveActivityManager.shared.update(conversationID, phase: .browsing, detail: step.title, force: true)
        return step.id
    }

    private func updateStep(_ stepID: UUID, status: AgentStep.Status, title: String?, in messageID: UUID, conversationID: UUID) {
        guard case let (ci, mi)? = messageIndices(messageID, conversationID),
              let si = conversations[ci].messages[mi].steps?.firstIndex(where: { $0.id == stepID }) else { return }
        conversations[ci].messages[mi].steps?[si].status = status
        if let title { conversations[ci].messages[mi].steps?[si].title = title }
    }

    private func finishRunningSteps(_ messageID: UUID, in conversationID: UUID) {
        guard case let (ci, mi)? = messageIndices(messageID, conversationID),
              let steps = conversations[ci].messages[mi].steps else { return }
        for si in steps.indices where steps[si].status == .running {
            conversations[ci].messages[mi].steps?[si].status = .failed
        }
    }
}
