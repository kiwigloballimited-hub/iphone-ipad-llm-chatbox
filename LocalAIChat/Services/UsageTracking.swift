import Foundation

// MARK: - Token 估算（服务器没有返回用量时使用）

enum TokenEstimator {
    /// 每张图片 / 视频帧大约占用的 token
    static let imageTokens = 800
    /// 每条消息的格式开销
    static let messageOverhead = 4
    /// 浏览器工具定义和说明大约占用的 token
    static let browserToolsOverhead = 1500

    /// 粗略估算：中日韩文字约 1 字 1 token，其他文字约 4 个字符 1 token
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
                cjk += 1
            default:
                other += 1
            }
        }
        return Int((Double(cjk) + Double(other) / 3.8).rounded(.up))
    }

    static func estimate(messages: [RequestMessage]) -> Int {
        messages.reduce(0) { total, message in
            total + estimate(message.text) + message.imageFiles.count * imageTokens + messageOverhead
        }
    }

    static func estimate(entries: [AgentEntry]) -> Int {
        var total = browserToolsOverhead
        for entry in entries {
            switch entry {
            case .system(let text):
                total += estimate(text) + messageOverhead
            case .message(let message):
                total += estimate(message.text) + message.imageFiles.count * imageTokens + messageOverhead
            case .assistantTurn(let turn):
                total += estimate(turn.text) + turn.toolCalls.reduce(0) { $0 + estimate($1.rawArguments) + 10 } + messageOverhead
            case .toolResults(let results):
                total += results.reduce(0) { $0 + estimate($1.content) + messageOverhead }
            }
        }
        return total
    }

    static func estimateUsage(messages: [RequestMessage], output: String) -> TokenUsage {
        TokenUsage(inputTokens: estimate(messages: messages), outputTokens: estimate(output), estimated: true)
    }
}

// MARK: - 价格表

enum PriceBook {
    struct Entry {
        let prefix: String
        let price: ModelPrice
        /// true = 参考价，可能已经变化，建议用户核对
        let reference: Bool
    }

    /// 内置价格（美元 / 每百万 token）。按前缀匹配，较长的前缀写在前面。
    static let entries: [Entry] = [
        Entry(prefix: "claude-fable-5-1", price: ModelPrice(input: 10, output: 50, cachedInput: 0.25), reference: false),
        Entry(prefix: "claude-mythos-5-1", price: ModelPrice(input: 10, output: 50, cachedInput: 0.25), reference: false),
        Entry(prefix: "claude-fable-5", price: ModelPrice(input: 10, output: 50), reference: false),
        Entry(prefix: "claude-opus-5-5", price: ModelPrice(input: 4, output: 20, cachedInput: 0.20), reference: false),
        Entry(prefix: "claude-opus-5", price: ModelPrice(input: 5, output: 25), reference: false),
        Entry(prefix: "claude-opus-4-8", price: ModelPrice(input: 5, output: 25), reference: false),
        Entry(prefix: "claude-opus-4-7", price: ModelPrice(input: 5, output: 25), reference: false),
        Entry(prefix: "claude-opus-4-6", price: ModelPrice(input: 5, output: 25), reference: false),
        Entry(prefix: "claude-sonnet-5-5", price: ModelPrice(input: 2, output: 10, cachedInput: 0.20), reference: false),
        Entry(prefix: "claude-sonnet-5", price: ModelPrice(input: 2, output: 10), reference: false),
        Entry(prefix: "claude-sonnet-4-6", price: ModelPrice(input: 3, output: 15), reference: false),
        Entry(prefix: "claude-haiku-5-5", price: ModelPrice(input: 0.10, output: 0.50), reference: false),
        Entry(prefix: "claude-haiku-4-5", price: ModelPrice(input: 1, output: 5), reference: false),
        Entry(prefix: "deepseek-chat", price: ModelPrice(input: 0.28, output: 0.42, cachedInput: 0.028, cacheWrite: 0.28), reference: true),
        Entry(prefix: "deepseek-reasoner", price: ModelPrice(input: 0.28, output: 0.42, cachedInput: 0.028, cacheWrite: 0.28), reference: true),
    ]

    static func builtIn(_ model: String) -> Entry? {
        let id = model.lowercased()
        return entries.first { id.hasPrefix($0.prefix) }
    }

    /// 已知模型的上下文窗口（查询不到时的参考值）
    static func knownContextWindow(_ model: String) -> Int? {
        let id = model.lowercased()
        if id.hasPrefix("claude-haiku-4-5") { return 200_000 }
        if id.hasPrefix("claude-") { return 1_000_000 }
        if id.hasPrefix("deepseek-chat") || id.hasPrefix("deepseek-reasoner") { return 128_000 }
        return nil
    }

    /// 费用（美元）
    static func cost(_ usage: TokenUsage, price: ModelPrice) -> Double {
        let cached = usage.cachedInputTokens
        let written = usage.cacheWriteTokens
        let regular = max(0, usage.inputTokens - cached - written)
        let total = Double(regular) * price.input
            + Double(cached) * (price.cachedInput ?? price.input * 0.1)
            + Double(written) * (price.cacheWrite ?? price.input * 1.25)
            + Double(usage.outputTokens) * price.output
        return total / 1_000_000
    }
}

// MARK: - 会话统计

struct SessionStats {
    /// 对话回复消耗
    var usage = TokenUsage()
    /// 后台整理（摘要、记忆）消耗
    var background = TokenUsage()
    /// 正在生成、还没有统计的部分（估算）
    var streamingTokens = 0
    /// 预估费用（美元）；nil = 没有价格信息
    var cost: Double?
    /// 有部分模型没有价格信息
    var costIncomplete = false
    var isFree = false
    var contextUsed = 0
    var contextWindow: Int?
    var contextSource = ""
    var contextEstimated = true

    var totalTokens: Int { usage.totalTokens + background.totalTokens + streamingTokens }
    var estimated: Bool { usage.estimated || background.estimated || streamingTokens > 0 }

    var contextFraction: Double? {
        guard let window = contextWindow, window > 0 else { return nil }
        return min(1, Double(contextUsed) / Double(window))
    }
}

enum PriceSource {
    case custom
    case builtIn(reference: Bool)
    case local
    case unknown

    var label: String {
        switch self {
        case .custom: return "自定义价格"
        case .builtIn(let reference): return reference ? "内置参考价（请核对）" : "内置官方价格"
        case .local: return "本地模型，免费"
        case .unknown: return "未设置价格"
        }
    }
}

extension AppStore {
    // MARK: Prices

    func price(for model: String, server: ServerConfig?) -> (price: ModelPrice?, source: PriceSource) {
        if let custom = customPrices[model] { return (custom, .custom) }
        if let entry = PriceBook.builtIn(model) { return (entry.price, .builtIn(reference: entry.reference)) }
        if Self.isLocal(server) { return (.free, .local) }
        return (nil, .unknown)
    }

    func setCustomPrice(_ price: ModelPrice?, for model: String) {
        customPrices[model] = price
        save()
    }

    /// 本地 / 局域网 / Tailscale 服务器视为免费
    static func isLocal(_ server: ServerConfig?) -> Bool {
        guard let server else { return false }
        if server.apiType == .ollama { return true }
        var text = server.baseURL.trimmed.lowercased()
        if !text.hasPrefix("http") { text = "http://" + text }
        guard let host = URL(string: text)?.host else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".ts.net") || !host.contains(".") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true // Tailscale / CGNAT
        default: return false
        }
    }

    /// 所有用到的模型（用于价格设置页）
    func modelsInUse() -> [(model: String, server: ServerConfig?)] {
        var seen = Set<String>()
        var result: [(model: String, server: ServerConfig?)] = []
        for agent in agents {
            let model = effectiveModel(for: agent)
            guard !model.isEmpty, seen.insert(model).inserted else { continue }
            result.append((model, server(for: agent)))
        }
        for conversation in conversations {
            let conversationServer = agent(id: conversation.agentID).flatMap { server(for: $0) }
            for message in conversation.messages {
                guard let model = message.modelName, !model.isEmpty, seen.insert(model).inserted else { continue }
                result.append((model, conversationServer))
            }
        }
        for model in customPrices.keys where seen.insert(model).inserted {
            result.append((model, nil))
        }
        return result
    }

    // MARK: Context window

    private func contextKey(for agent: Agent) -> String? {
        guard let server = server(for: agent) else { return nil }
        let model = effectiveModel(for: agent)
        guard !model.isEmpty else { return nil }
        return server.id.uuidString + "|" + model
    }

    func contextWindow(for agent: Agent) -> (value: Int?, source: String) {
        if let manual = agent.contextWindowOverride { return (manual, "手动设置") }
        if let key = contextKey(for: agent), let detected = contextWindows[key] { return (detected, "自动检测") }
        if let known = PriceBook.knownContextWindow(effectiveModel(for: agent)) { return (known, "参考值") }
        return (nil, "未知")
    }

    /// 自动检测上下文窗口。force = true 时即使之前检测失败也再试一次（例如 Ollama 模型加载之后）
    func detectContextWindowIfNeeded(for agent: Agent, force: Bool = false) async {
        guard agent.contextWindowOverride == nil,
              let key = contextKey(for: agent),
              let agentServer = server(for: agent) else { return }
        if !force {
            guard contextWindows[key] == nil, !contextDetectionAttempted.contains(key) else { return }
        }
        contextDetectionAttempted.insert(key)
        if let value = await LLMClient(server: agentServer).detectContextWindow(model: effectiveModel(for: agent)) {
            if contextWindows[key] != value {
                contextWindows[key] = value
                save()
            }
        }
    }

    // MARK: Usage recording

    func addBackgroundUsage(_ usage: TokenUsage, to conversationID: UUID) {
        guard let i = conversationIndex(conversationID) else { return }
        var current = conversations[i].backgroundUsage ?? TokenUsage()
        current.add(usage)
        conversations[i].backgroundUsage = current
        save()
    }

    // MARK: Stats

    func sessionStats(for conversationID: UUID, draft: String = "") -> SessionStats? {
        guard let conversation = conversation(id: conversationID),
              let agent = agent(id: conversation.agentID) else { return nil }
        let agentServer = server(for: agent)
        var stats = SessionStats()
        var cost = 0.0
        var anyPrice = false
        var allFree = true

        func account(_ usage: TokenUsage, model: String) {
            let lookup = price(for: model, server: agentServer)
            if let price = lookup.price {
                cost += PriceBook.cost(usage, price: price)
                anyPrice = true
                if price != .free { allFree = false }
            } else {
                stats.costIncomplete = true
                allFree = false
            }
        }

        let defaultModel = effectiveModel(for: agent)
        for message in conversation.messages where message.role == .assistant {
            guard let usage = message.usage else { continue }
            stats.usage.add(usage)
            account(usage, model: message.modelName ?? defaultModel)
        }
        if let background = conversation.backgroundUsage {
            stats.background = background
            account(background, model: defaultModel)
        }

        // 正在生成、还没有收到用量统计的回复
        if isGenerating(conversationID), let last = conversation.messages.last, last.role == .assistant, last.usage == nil {
            stats.streamingTokens = TokenEstimator.estimate(last.content + last.reasoning)
            account(TokenUsage(outputTokens: stats.streamingTokens, estimated: true), model: last.modelName ?? defaultModel)
        }

        stats.cost = anyPrice ? cost : nil
        stats.isFree = allFree && anyPrice
        if !anyPrice && stats.totalTokens == 0 && Self.isLocal(agentServer) { stats.isFree = true }

        // 上下文占用：最近一次真实请求的输入 + 输出，加上之后新增的内容
        let draftTokens = TokenEstimator.estimate(draft)
        let lastUsageIndex = conversation.messages.lastIndex { $0.role == .assistant && ($0.usage?.lastInputTokens ?? 0) > 0 }
        // 手动调整过上下文（置顶 / 排除 / 起点）之后，上次的真实数字不再适用，改为整体估算
        let editedSinceUsage: Bool = {
            guard let edited = conversation.contextEditedAt, let index = lastUsageIndex else { return false }
            return edited > conversation.messages[index].createdAt
        }()
        if !editedSinceUsage, let index = lastUsageIndex,
           let usage = conversation.messages[index].usage {
            var used = usage.lastInputTokens + usage.lastOutputTokens
            for message in conversation.messages[(index + 1)...] {
                used += TokenEstimator.estimate(message.content) + message.attachments.count * TokenEstimator.imageTokens
            }
            stats.contextUsed = used + draftTokens
            stats.contextEstimated = usage.estimated || index < conversation.messages.count - 1 || draftTokens > 0
        } else {
            var used = TokenEstimator.estimate(messages: buildRequestMessages(conversation: conversation, agent: agent))
            if agent.browserEnabled { used += TokenEstimator.browserToolsOverhead }
            stats.contextUsed = used + draftTokens
            stats.contextEstimated = true
        }
        let window = contextWindow(for: agent)
        stats.contextWindow = window.value
        stats.contextSource = window.source
        return stats
    }

    /// 单条回复的用量说明，例如「↑1.2K ↓350 · $0.003」
    func usageCaption(for message: ChatMessage, agent: Agent?) -> String? {
        guard let usage = message.usage, usage.totalTokens > 0 else { return nil }
        let prefix = usage.estimated ? "≈" : ""
        var text = "\(prefix)↑\(Self.formatTokens(usage.inputTokens)) ↓\(Self.formatTokens(usage.outputTokens))"
        if let model = message.modelName ?? agent.map({ effectiveModel(for: $0) }) {
            let lookup = price(for: model, server: agent.flatMap { server(for: $0) })
            if let price = lookup.price, price != .free {
                text += " · " + formatCost(PriceBook.cost(usage, price: price))
            }
        }
        return text
    }

    // MARK: Formatting

    func formatCost(_ usd: Double) -> String {
        let value = usd * media.currencyRate
        let symbol = media.currency.symbol
        if value == 0 { return symbol + "0" }
        if value < 0.0001 { return "<" + symbol + "0.0001" }
        if value < 0.01 { return symbol + String(format: "%.4f", value) }
        if value < 1 { return symbol + String(format: "%.3f", value) }
        return symbol + String(format: "%.2f", value)
    }

    static func formatTokens(_ count: Int) -> String {
        switch count {
        case ..<1000: return "\(count)"
        case ..<10_000: return String(format: "%.1fK", Double(count) / 1000)
        case ..<1_000_000: return "\(count / 1000)K"
        default: return String(format: "%.2fM", Double(count) / 1_000_000)
        }
    }
}
