import Foundation

// MARK: - Provider-neutral tool calling types

/// 提供给模型的一个工具（JSON Schema 描述参数）
struct ToolSpec {
    let name: String
    let description: String
    let parameters: [String: Any]
}

struct ToolCall {
    let id: String
    let name: String
    /// nil 表示模型给出的参数不是合法 JSON
    let arguments: [String: Any]?
    let rawArguments: String
}

struct ToolResult {
    let callID: String
    let name: String
    let content: String
    let isError: Bool
}

/// 模型一轮的完整输出
struct AssistantTurn {
    var text: String
    var reasoning: String
    var toolCalls: [ToolCall]
    /// 原样回传给服务器的 assistant 消息（保留思考块、签名、工具调用等，Anthropic 要求在工具循环中原样回传）
    var rawMessage: [String: Any]
    var stopReason: String?
}

/// 工具循环中的一条记录
enum AgentEntry {
    case system(String)
    case message(RequestMessage)
    case assistantTurn(AssistantTurn)
    case toolResults([ToolResult])
}

enum TurnEvent {
    case content(String)
    case reasoning(String)
    case finished(AssistantTurn)
}

extension LLMClient {
    static let anthropicVersion = "2026-10-21"

    /// 流式请求一轮（可带工具）。支持 OpenAI 兼容、Ollama 原生、Anthropic 三种接口。
    func streamTurn(entries: [AgentEntry], tools: [ToolSpec], options: GenerationOptions) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try buildTurnRequest(entries: entries, tools: tools, options: options, compatibilityMode: false)
                    var (bytes, response) = try await session.bytes(for: request)
                    guard var http = response as? HTTPURLResponse else { throw LLMError.badResponse }

                    // 服务器 / 模型不认识扩展参数（思考、重复惩罚、回退等）时，只用标准参数重试一次
                    let usesExtensions = server.apiType == .anthropic || options.thinking != .auto || options.penalties != nil
                    if usesExtensions && [400, 422].contains(http.statusCode) {
                        request = try buildTurnRequest(entries: entries, tools: tools, options: options, compatibilityMode: true)
                        (bytes, response) = try await session.bytes(for: request)
                        guard let retried = response as? HTTPURLResponse else { throw LLMError.badResponse }
                        http = retried
                    }

                    if !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 4000 { break }
                        }
                        throw LLMError.http(http.statusCode, body)
                    }

                    var parser = TurnParser(apiType: server.apiType)
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for event in try parser.consume(line) {
                            continuation.yield(event)
                        }
                        if parser.isDone { break }
                    }
                    continuation.yield(.finished(parser.finish()))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Request building

    func buildTurnRequest(entries: [AgentEntry], tools: [ToolSpec], options: GenerationOptions, compatibilityMode: Bool) throws -> URLRequest {
        switch server.apiType {
        case .openAI: return try buildOpenAITurn(entries, tools, options, compatibilityMode)
        case .ollama: return try buildOllamaTurn(entries, tools, options, compatibilityMode)
        case .anthropic: return try buildAnthropicTurn(entries, tools, options, compatibilityMode)
        }
    }

    private func buildOpenAITurn(_ entries: [AgentEntry], _ tools: [ToolSpec], _ options: GenerationOptions, _ compatibilityMode: Bool) throws -> URLRequest {
        var messages: [[String: Any]] = []
        for entry in entries {
            switch entry {
            case .system(let text):
                messages.append(["role": "system", "content": text])
            case .message(let message):
                messages.append(Self.openAIMessage(message))
            case .assistantTurn(let turn):
                messages.append(turn.rawMessage)
            case .toolResults(let results):
                for result in results {
                    messages.append(["role": "tool", "tool_call_id": result.callID, "content": result.content])
                }
            }
        }
        var body: [String: Any] = [
            "model": options.model,
            "messages": messages,
            "stream": true,
            "temperature": options.temperature,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map(Self.openAITool)
        }
        if options.maxTokens > 0 { body["max_tokens"] = options.maxTokens }
        if let penalties = options.penalties {
            body["frequency_penalty"] = penalties.frequencyPenalty
            body["presence_penalty"] = penalties.presencePenalty
            if !compatibilityMode {
                body["repeat_penalty"] = penalties.repeatPenalty
                body["repetition_penalty"] = penalties.repeatPenalty
                body["repeat_last_n"] = penalties.repeatLastN
            }
        }
        if !compatibilityMode {
            body.merge(Self.openAIThinkingParameters(options.thinking)) { _, new in new }
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        return makeRequest(url: try openAIURL("/chat/completions"), method: "POST", body: data)
    }

    private func buildOllamaTurn(_ entries: [AgentEntry], _ tools: [ToolSpec], _ options: GenerationOptions, _ compatibilityMode: Bool) throws -> URLRequest {
        var messages: [[String: Any]] = []
        for entry in entries {
            switch entry {
            case .system(let text):
                messages.append(["role": "system", "content": text])
            case .message(let message):
                var item: [String: Any] = ["role": message.role.rawValue, "content": message.text]
                let images = message.imageFiles.compactMap(Storage.loadAttachment).map { $0.base64EncodedString() }
                if !images.isEmpty { item["images"] = images }
                messages.append(item)
            case .assistantTurn(let turn):
                messages.append(turn.rawMessage)
            case .toolResults(let results):
                for result in results {
                    messages.append(["role": "tool", "content": result.content, "tool_name": result.name])
                }
            }
        }
        var modelOptions: [String: Any] = ["temperature": options.temperature]
        if options.maxTokens > 0 { modelOptions["num_predict"] = options.maxTokens }
        if let penalties = options.penalties {
            modelOptions["repeat_penalty"] = penalties.repeatPenalty
            modelOptions["repeat_last_n"] = penalties.repeatLastN
            modelOptions["frequency_penalty"] = penalties.frequencyPenalty
            modelOptions["presence_penalty"] = penalties.presencePenalty
        }
        var body: [String: Any] = [
            "model": options.model,
            "messages": messages,
            "stream": true,
            "options": modelOptions,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map(Self.openAITool)
        }
        if !compatibilityMode, let think = Self.ollamaThinkValue(options.thinking, model: options.model) {
            body["think"] = think
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        return makeRequest(url: try ollamaURL("/api/chat"), method: "POST", body: data)
    }

    private func buildAnthropicTurn(_ entries: [AgentEntry], _ tools: [ToolSpec], _ options: GenerationOptions, _ compatibilityMode: Bool) throws -> URLRequest {
        var systemParts: [String] = []
        var messages: [[String: Any]] = []

        // 相邻同角色的消息合并为一条（内容块拼接）
        func append(role: String, blocks: [[String: Any]]) {
            let blocks = blocks.filter { block in
                !((block["type"] as? String) == "text" && ((block["text"] as? String) ?? "").isEmpty)
            }
            guard !blocks.isEmpty else { return }
            if var last = messages.last, (last["role"] as? String) == role,
               var existing = last["content"] as? [[String: Any]] {
                existing.append(contentsOf: blocks)
                last["content"] = existing
                messages[messages.count - 1] = last
            } else {
                messages.append(["role": role, "content": blocks])
            }
        }

        for entry in entries {
            switch entry {
            case .system(let text):
                systemParts.append(text)
            case .message(let message):
                switch message.role {
                case .system:
                    systemParts.append(message.text)
                case .user:
                    var blocks: [[String: Any]] = message.imageFiles.compactMap(Storage.loadAttachment).map { data in
                        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]]
                    }
                    blocks.append(["type": "text", "text": message.text])
                    append(role: "user", blocks: blocks)
                case .assistant:
                    append(role: "assistant", blocks: [["type": "text", "text": message.text]])
                }
            case .assistantTurn(let turn):
                append(role: "assistant", blocks: turn.rawMessage["content"] as? [[String: Any]] ?? [])
            case .toolResults(let results):
                append(role: "user", blocks: results.map { result in
                    ["type": "tool_result", "tool_use_id": result.callID, "content": result.content, "is_error": result.isError]
                })
            }
        }

        var body: [String: Any] = [
            "model": options.model,
            "max_tokens": options.maxTokens > 0 ? options.maxTokens : 64000,
            "stream": true,
            "messages": messages,
        ]
        let system = systemParts.joined(separator: "\n\n").trimmed
        if !system.isEmpty { body["system"] = system }
        if !tools.isEmpty {
            // 流式 + 自定义工具：开启 eager_input_streaming，参数在客户端校验
            body["tools"] = tools.map { tool in
                ["name": tool.name, "description": tool.description, "input_schema": tool.parameters, "eager_input_streaming": true] as [String: Any]
            }
        }

        var headers: [String: String] = [:]
        if !compatibilityMode {
            // 自适应思考，并返回可读的思考摘要
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
            switch options.thinking {
            case .auto: break
            case .off: body["output_config"] = ["effort": "low"]
            case .low, .medium, .high: body["output_config"] = ["effort": options.thinking.rawValue]
            }
            // 安全分类器拒绝时，由服务器自动改用推荐的回退模型
            if Self.supportsServerFallback(options.model) {
                body["fallbacks"] = "default"
                headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
            }
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        return makeRequest(url: try anthropicURL("/messages"), method: "POST", body: data, extraHeaders: headers)
    }

    static func supportsServerFallback(_ model: String) -> Bool {
        let id = model.lowercased()
        return ["claude-fable-5-1", "claude-opus-5", "claude-sonnet-5-5"].contains { id.hasPrefix($0) }
    }

    static func openAITool(_ tool: ToolSpec) -> [String: Any] {
        ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": tool.parameters] as [String: Any]]
    }

    static func openAIMessage(_ message: RequestMessage) -> [String: Any] {
        let images = message.imageFiles.compactMap(Storage.loadAttachment)
        if images.isEmpty {
            return ["role": message.role.rawValue, "content": message.text]
        }
        var parts: [[String: Any]] = []
        if !message.text.isEmpty {
            parts.append(["type": "text", "text": message.text])
        }
        for data in images {
            parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + data.base64EncodedString()]])
        }
        return ["role": message.role.rawValue, "content": parts]
    }

    static func parseJSONObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmed
        if trimmed.isEmpty { return [:] }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Stream parser

private struct PartialToolCall {
    var id = ""
    var name = ""
    var arguments = ""
}

/// 解析三种接口的流式输出，最后组装成 AssistantTurn
struct TurnParser {
    let apiType: APIType
    private(set) var isDone = false
    private var text = ""
    private var reasoning = ""
    private var stopReason: String?

    // OpenAI
    private var openAICalls: [Int: PartialToolCall] = [:]
    private var usedReasoningContent = false
    // Ollama
    private var ollamaCalls: [[String: Any]] = []
    // Anthropic
    private var blocks: [Int: [String: Any]] = [:]
    private var partialJSON: [Int: String] = [:]
    private var invalidToolBlocks: Set<Int> = []

    init(apiType: APIType) {
        self.apiType = apiType
    }

    mutating func consume(_ rawLine: String) throws -> [TurnEvent] {
        var line = rawLine.trimmed
        guard !line.isEmpty, !line.hasPrefix(":"), !line.hasPrefix("event:") else { return [] }
        if line.hasPrefix("data:") {
            line = String(line.dropFirst(5)).trimmed
            if line == "[DONE]" {
                isDone = true
                return []
            }
        }
        guard let data = line.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }

        switch apiType {
        case .openAI: return try consumeOpenAI(json)
        case .ollama: return try consumeOllama(json)
        case .anthropic: return try consumeAnthropic(json)
        }
    }

    private func checkError(_ json: [String: Any]) throws {
        if let error = json["error"] {
            if let dict = error as? [String: Any], let message = dict["message"] as? String {
                throw LLMError.server(message)
            }
            throw LLMError.server(String(describing: error))
        }
    }

    private mutating func consumeOpenAI(_ json: [String: Any]) throws -> [TurnEvent] {
        try checkError(json)
        guard let choices = json["choices"] as? [[String: Any]], let choice = choices.first else { return [] }
        let delta = (choice["delta"] as? [String: Any]) ?? (choice["message"] as? [String: Any]) ?? [:]
        var events: [TurnEvent] = []

        if let value = delta["reasoning_content"] as? String, !value.isEmpty {
            usedReasoningContent = true
            reasoning += value
            events.append(.reasoning(value))
        } else if let value = delta["reasoning"] as? String, !value.isEmpty {
            reasoning += value
            events.append(.reasoning(value))
        }
        if let value = delta["content"] as? String, !value.isEmpty {
            text += value
            events.append(.content(value))
        }
        if let calls = delta["tool_calls"] as? [[String: Any]] {
            for (position, call) in calls.enumerated() {
                let index = call["index"] as? Int ?? position
                var partial = openAICalls[index] ?? PartialToolCall()
                if let id = call["id"] as? String, !id.isEmpty { partial.id = id }
                if let function = call["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty, partial.name.isEmpty {
                        partial.name = name
                    }
                    if let arguments = function["arguments"] as? String {
                        partial.arguments += arguments
                    } else if let object = function["arguments"] as? [String: Any],
                              let data = try? JSONSerialization.data(withJSONObject: object),
                              let string = String(data: data, encoding: .utf8) {
                        partial.arguments = string
                    }
                }
                openAICalls[index] = partial
            }
        }
        if let finish = choice["finish_reason"] as? String {
            stopReason = finish
        }
        return events
    }

    private mutating func consumeOllama(_ json: [String: Any]) throws -> [TurnEvent] {
        try checkError(json)
        var events: [TurnEvent] = []
        if let message = json["message"] as? [String: Any] {
            if let value = message["thinking"] as? String, !value.isEmpty {
                reasoning += value
                events.append(.reasoning(value))
            }
            if let value = message["content"] as? String, !value.isEmpty {
                text += value
                events.append(.content(value))
            }
            if let calls = message["tool_calls"] as? [[String: Any]] {
                ollamaCalls.append(contentsOf: calls)
            }
        }
        if json["done"] as? Bool == true {
            isDone = true
            stopReason = json["done_reason"] as? String
        }
        return events
    }

    private mutating func consumeAnthropic(_ json: [String: Any]) throws -> [TurnEvent] {
        let type = json["type"] as? String ?? ""
        switch type {
        case "error":
            let error = json["error"] as? [String: Any]
            throw LLMError.server(error?["message"] as? String ?? "未知错误")

        case "content_block_start":
            guard let index = json["index"] as? Int, var block = json["content_block"] as? [String: Any] else { return [] }
            if block["type"] as? String == "tool_use" {
                block["input"] = [String: Any]()
                partialJSON[index] = ""
            }
            blocks[index] = block
            return []

        case "content_block_delta":
            guard let index = json["index"] as? Int, let delta = json["delta"] as? [String: Any] else { return [] }
            var block = blocks[index] ?? [:]
            var events: [TurnEvent] = []
            switch delta["type"] as? String {
            case "text_delta":
                let value = delta["text"] as? String ?? ""
                block["text"] = (block["text"] as? String ?? "") + value
                text += value
                if !value.isEmpty { events.append(.content(value)) }
            case "thinking_delta":
                let value = delta["thinking"] as? String ?? ""
                block["thinking"] = (block["thinking"] as? String ?? "") + value
                reasoning += value
                if !value.isEmpty { events.append(.reasoning(value)) }
            case "signature_delta":
                block["signature"] = delta["signature"] as? String ?? ""
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
            default:
                break
            }
            blocks[index] = block
            return events

        case "content_block_stop":
            guard let index = json["index"] as? Int, var block = blocks[index] else { return [] }
            if block["type"] as? String == "tool_use" {
                // eager_input_streaming 下服务器不校验参数，这里严格解析
                if let object = LLMClient.parseJSONObject(partialJSON[index] ?? "") {
                    block["input"] = object
                } else {
                    invalidToolBlocks.insert(index)
                }
                blocks[index] = block
            }
            return []

        case "message_delta":
            if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                stopReason = reason
            }
            return []

        case "message_stop":
            isDone = true
            return []

        default:
            return []
        }
    }

    func finish() -> AssistantTurn {
        switch apiType {
        case .openAI:
            let calls = openAICalls.keys.sorted().compactMap { index -> ToolCall? in
                guard let partial = openAICalls[index], !partial.name.isEmpty else { return nil }
                let id = partial.id.isEmpty ? "call_\(index)" : partial.id
                return ToolCall(id: id, name: partial.name, arguments: LLMClient.parseJSONObject(partial.arguments), rawArguments: partial.arguments)
            }
            var raw: [String: Any] = ["role": "assistant", "content": text]
            if !calls.isEmpty {
                raw["tool_calls"] = calls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": ["name": call.name, "arguments": call.rawArguments.trimmed.isEmpty ? "{}" : call.rawArguments],
                    ] as [String: Any]
                }
            }
            // DeepSeek 等在同一轮工具调用中要求回传 reasoning_content
            if usedReasoningContent && !reasoning.isEmpty {
                raw["reasoning_content"] = reasoning
            }
            return AssistantTurn(text: text, reasoning: reasoning, toolCalls: calls, rawMessage: raw, stopReason: stopReason)

        case .ollama:
            var calls: [ToolCall] = []
            for (index, call) in ollamaCalls.enumerated() {
                guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { continue }
                var arguments = function["arguments"] as? [String: Any]
                var rawArguments = ""
                if let object = arguments, let data = try? JSONSerialization.data(withJSONObject: object) {
                    rawArguments = String(data: data, encoding: .utf8) ?? ""
                } else if let string = function["arguments"] as? String {
                    rawArguments = string
                    arguments = LLMClient.parseJSONObject(string)
                }
                calls.append(ToolCall(id: "call_\(index)", name: name, arguments: arguments, rawArguments: rawArguments))
            }
            var raw: [String: Any] = ["role": "assistant", "content": text]
            if !ollamaCalls.isEmpty { raw["tool_calls"] = ollamaCalls }
            return AssistantTurn(text: text, reasoning: reasoning, toolCalls: calls, rawMessage: raw, stopReason: stopReason)

        case .anthropic:
            let indices = blocks.keys.sorted()
            let ordered = indices.compactMap { blocks[$0] }
            // 服务器端回退（fallback）时：最后一个 fallback 块之前，只保留文字块回传
            let boundary = ordered.lastIndex { $0["type"] as? String == "fallback" }
            var replay: [[String: Any]] = []
            var calls: [ToolCall] = []
            for (position, block) in ordered.enumerated() {
                let type = block["type"] as? String
                if let boundary, position <= boundary {
                    if type == "text", let value = block["text"] as? String, !value.isEmpty { replay.append(block) }
                    continue
                }
                if type == "text", ((block["text"] as? String) ?? "").isEmpty { continue }
                replay.append(block)
                if type == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String {
                    let index = indices[position]
                    let invalid = invalidToolBlocks.contains(index)
                    calls.append(ToolCall(
                        id: id,
                        name: name,
                        arguments: invalid ? nil : block["input"] as? [String: Any],
                        rawArguments: partialJSON[index] ?? ""
                    ))
                }
            }
            let raw: [String: Any] = ["role": "assistant", "content": replay]
            return AssistantTurn(text: text, reasoning: reasoning, toolCalls: calls, rawMessage: raw, stopReason: stopReason)
        }
    }
}
