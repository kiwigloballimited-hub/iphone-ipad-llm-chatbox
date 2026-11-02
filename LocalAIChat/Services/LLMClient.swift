import Foundation

/// 发送给模型的一条消息（图片以附件文件名表示，在发送时才读取并 base64 编码）
struct RequestMessage {
    var role: Role
    var text: String
    var imageFiles: [String] = []
}

struct GenerationOptions {
    var model: String
    var temperature: Double
    var maxTokens: Int
    var thinking: ThinkingLevel = .auto
    var penalties: PenaltySettings?
}

enum StreamEvent {
    case content(String)
    case reasoning(String)
}

enum LLMError: LocalizedError {
    case invalidURL(String)
    case http(Int, String)
    case server(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "服务器地址无效：\(url)"
        case .http(let code, let body):
            let detail = LLMError.extractMessage(from: body) ?? body
            return "服务器返回错误 \(code)：\(detail.prefix(500))"
        case .server(let message):
            return "服务器错误：\(message)"
        case .badResponse:
            return "无法解析服务器的响应。"
        }
    }

    static func extractMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let error = json["error"] as? String { return error }
        if let message = json["message"] as? String { return message }
        return nil
    }

    /// 把常见的网络错误翻译成可操作的提示
    static func friendlyDescription(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost:
                return "无法连接到服务器。请检查：\n1. 地址和端口是否正确；\n2. 服务器是否允许局域网访问（Ollama 需设置环境变量 OLLAMA_HOST=0.0.0.0，LM Studio 需开启「在局域网中提供服务」）；\n3. 电脑防火墙是否放行该端口。"
            case .notConnectedToInternet, .networkConnectionLost:
                return "网络不可用。请确认设备已连接到与服务器相同的 Wi-Fi，并在「设置 › 隐私与安全性 › 本地网络」中允许本应用访问。"
            case .timedOut:
                return "请求超时。模型可能仍在加载，或者图片/视频帧太多，请稍后重试或减少附件。"
            case .appTransportSecurityRequiresSecureConnection:
                return "系统阻止了不安全的 HTTP 连接。"
            default:
                return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

struct LLMClient {
    let server: ServerConfig
    var session: URLSession = .shared

    // MARK: URL helpers

    private var normalizedBase: String {
        var base = server.baseURL.trimmed
        while base.hasSuffix("/") { base.removeLast() }
        let lower = base.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            base = "http://" + base
        }
        return base
    }

    private func openAIURL(_ path: String) throws -> URL {
        var base = normalizedBase
        if !base.hasSuffix("/v1") { base += "/v1" }
        guard let url = URL(string: base + path) else { throw LLMError.invalidURL(server.baseURL) }
        return url
    }

    private func ollamaURL(_ path: String) throws -> URL {
        var base = normalizedBase
        if base.hasSuffix("/v1") { base.removeLast(3) }
        guard let url = URL(string: base + path) else { throw LLMError.invalidURL(server.baseURL) }
        return url
    }

    private func makeRequest(url: URL, method: String, body: Data? = nil, timeout: TimeInterval = 600) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.apiKey.isBlank {
            request.setValue("Bearer \(server.apiKey.trimmed)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return request
    }

    // MARK: Models

    func listModels() async throws -> [String] {
        switch server.apiType {
        case .openAI:
            let request = makeRequest(url: try openAIURL("/models"), method: "GET", timeout: 15)
            let (data, response) = try await session.data(for: request)
            try check(response, data)
            struct Response: Decodable {
                struct Model: Decodable { let id: String }
                let data: [Model]
            }
            return try JSONDecoder().decode(Response.self, from: data).data.map(\.id).sorted()
        case .ollama:
            let request = makeRequest(url: try ollamaURL("/api/tags"), method: "GET", timeout: 15)
            let (data, response) = try await session.data(for: request)
            try check(response, data)
            struct Response: Decodable {
                struct Model: Decodable { let name: String }
                let models: [Model]
            }
            return try JSONDecoder().decode(Response.self, from: data).models.map(\.name).sorted()
        }
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: Chat (streaming)

    func streamChat(messages: [RequestMessage], options: GenerationOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try buildChatRequest(messages: messages, options: options, compatibilityMode: false)
                    var (bytes, response) = try await session.bytes(for: request)
                    guard var http = response as? HTTPURLResponse else { throw LLMError.badResponse }

                    // 部分服务器 / 模型不认识思考参数或非标准的重复惩罚参数，此时去掉这些参数重试一次
                    let usesExtensions = options.thinking != .auto || options.penalties != nil
                    if usesExtensions && [400, 422].contains(http.statusCode) {
                        request = try buildChatRequest(messages: messages, options: options, compatibilityMode: true)
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

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        let (events, done) = try parse(line: line)
                        for event in events { continuation.yield(event) }
                        if done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 一次性获取完整回复（用于记忆提取、摘要等后台任务）。会去掉 <think> 部分。
    func complete(messages: [RequestMessage], options: GenerationOptions) async throws -> String {
        var text = ""
        for try await event in streamChat(messages: messages, options: options) {
            if case .content(let piece) = event { text += piece }
        }
        return ThinkParser.split(text).answer.trimmed
    }

    /// - Parameter compatibilityMode: true 时只发送标准参数（不发送思考参数和非标准的重复惩罚参数）
    private func buildChatRequest(messages: [RequestMessage], options: GenerationOptions, compatibilityMode: Bool) throws -> URLRequest {
        var body: [String: Any]
        let url: URL

        switch server.apiType {
        case .openAI:
            url = try openAIURL("/chat/completions")
            let payload: [[String: Any]] = messages.map { message in
                let images = message.imageFiles.compactMap(Storage.loadAttachment)
                if images.isEmpty {
                    return ["role": message.role.rawValue, "content": message.text]
                }
                var parts: [[String: Any]] = []
                if !message.text.isEmpty {
                    parts.append(["type": "text", "text": message.text])
                }
                for data in images {
                    parts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:image/jpeg;base64," + data.base64EncodedString()],
                    ])
                }
                return ["role": message.role.rawValue, "content": parts]
            }
            body = [
                "model": options.model,
                "messages": payload,
                "stream": true,
                "temperature": options.temperature,
            ]
            if options.maxTokens > 0 { body["max_tokens"] = options.maxTokens }
            if let penalties = options.penalties {
                body["frequency_penalty"] = penalties.frequencyPenalty
                body["presence_penalty"] = penalties.presencePenalty
                if !compatibilityMode {
                    // 非标准参数：llama.cpp / LM Studio 使用 repeat_penalty，vLLM 使用 repetition_penalty
                    body["repeat_penalty"] = penalties.repeatPenalty
                    body["repetition_penalty"] = penalties.repeatPenalty
                    body["repeat_last_n"] = penalties.repeatLastN
                }
            }
            if !compatibilityMode {
                body.merge(Self.openAIThinkingParameters(options.thinking)) { _, new in new }
            }

        case .ollama:
            url = try ollamaURL("/api/chat")
            let payload: [[String: Any]] = messages.map { message in
                var item: [String: Any] = ["role": message.role.rawValue, "content": message.text]
                let images = message.imageFiles.compactMap(Storage.loadAttachment).map { $0.base64EncodedString() }
                if !images.isEmpty { item["images"] = images }
                return item
            }
            var modelOptions: [String: Any] = ["temperature": options.temperature]
            if options.maxTokens > 0 { modelOptions["num_predict"] = options.maxTokens }
            if let penalties = options.penalties {
                modelOptions["repeat_penalty"] = penalties.repeatPenalty
                modelOptions["repeat_last_n"] = penalties.repeatLastN
                modelOptions["frequency_penalty"] = penalties.frequencyPenalty
                modelOptions["presence_penalty"] = penalties.presencePenalty
            }
            body = [
                "model": options.model,
                "messages": payload,
                "stream": true,
                "options": modelOptions,
            ]
            if !compatibilityMode, let think = Self.ollamaThinkValue(options.thinking, model: options.model) {
                body["think"] = think
            }
        }

        let data = try JSONSerialization.data(withJSONObject: body)
        return makeRequest(url: url, method: "POST", body: data)
    }

    // MARK: Thinking

    /// OpenAI 兼容接口：
    /// - reasoning_effort：gpt-oss（LM Studio / vLLM / Ollama）等支持分级的模型
    /// - chat_template_kwargs.enable_thinking：Qwen3 等通过聊天模板开关思考的模型（vLLM / llama.cpp）
    static func openAIThinkingParameters(_ level: ThinkingLevel) -> [String: Any] {
        switch level {
        case .auto:
            return [:]
        case .off:
            return [
                "reasoning_effort": "none",
                "chat_template_kwargs": ["enable_thinking": false],
            ]
        case .low, .medium, .high:
            return [
                "reasoning_effort": level.rawValue,
                "chat_template_kwargs": ["enable_thinking": true],
            ]
        }
    }

    /// Ollama 原生接口的 think 参数：gpt-oss 支持 "low" / "medium" / "high"，其他模型只支持开 / 关
    static func ollamaThinkValue(_ level: ThinkingLevel, model: String) -> Any? {
        switch level {
        case .auto:
            return nil
        case .off:
            return false
        case .low, .medium, .high:
            return model.lowercased().contains("gpt-oss") ? level.rawValue : true
        }
    }

    /// 解析一行流式数据。OpenAI 为 SSE（data: {...}），Ollama 为 NDJSON。
    private func parse(line rawLine: String) throws -> (events: [StreamEvent], done: Bool) {
        var line = rawLine.trimmed
        guard !line.isEmpty else { return ([], false) }

        if line.hasPrefix("data:") {
            line = String(line.dropFirst(5)).trimmed
            if line == "[DONE]" { return ([], true) }
        } else if line.hasPrefix(":") || line.hasPrefix("event:") {
            return ([], false)
        }

        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], false)
        }

        if let error = json["error"] {
            if let dict = error as? [String: Any], let message = dict["message"] as? String {
                throw LLMError.server(message)
            }
            throw LLMError.server(String(describing: error))
        }

        var events: [StreamEvent] = []

        // Ollama 原生
        if let message = json["message"] as? [String: Any] {
            if let thinking = message["thinking"] as? String, !thinking.isEmpty { events.append(.reasoning(thinking)) }
            if let content = message["content"] as? String, !content.isEmpty { events.append(.content(content)) }
            let done = json["done"] as? Bool ?? false
            return (events, done)
        }

        // OpenAI 兼容
        if let choices = json["choices"] as? [[String: Any]], let choice = choices.first {
            let delta = (choice["delta"] as? [String: Any]) ?? (choice["message"] as? [String: Any]) ?? [:]
            let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String)
            if let reasoning, !reasoning.isEmpty { events.append(.reasoning(reasoning)) }
            if let content = delta["content"] as? String, !content.isEmpty { events.append(.content(content)) }
            return (events, false)
        }

        return ([], false)
    }
}
