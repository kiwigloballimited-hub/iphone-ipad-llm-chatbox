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
    /// 服务器报告的 token 用量（通常在最后）
    case usage(TokenUsage)
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
            var hint = ""
            switch code {
            case 401, 403: hint = "\n\n提示：API Key 无效或没有权限，请在服务器设置中检查 API Key。"
            case 402: hint = "\n\n提示：账户余额不足。"
            case 429: hint = "\n\n提示：请求太频繁或额度已用完，请稍后再试。"
            case 529: hint = "\n\n提示：服务器繁忙，请稍后再试。"
            default: break
            }
            return "服务器返回错误 \(code)：\(detail.prefix(500))" + hint
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

    func openAIURL(_ path: String) throws -> URL {
        var base = normalizedBase
        if !base.hasSuffix("/v1") { base += "/v1" }
        guard let url = URL(string: base + path) else { throw LLMError.invalidURL(server.baseURL) }
        return url
    }

    func ollamaURL(_ path: String) throws -> URL {
        var base = normalizedBase
        if base.hasSuffix("/v1") { base.removeLast(3) }
        guard let url = URL(string: base + path) else { throw LLMError.invalidURL(server.baseURL) }
        return url
    }

    func anthropicURL(_ path: String) throws -> URL {
        var base = normalizedBase
        if base.hasSuffix("/v1") { base.removeLast(3) }
        guard let url = URL(string: base + "/v1" + path) else { throw LLMError.invalidURL(server.baseURL) }
        return url
    }

    func makeRequest(url: URL, method: String, body: Data? = nil, timeout: TimeInterval = 600, extraHeaders: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if server.apiType == .anthropic {
            request.setValue(server.apiKey.trimmed, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        } else if !server.apiKey.isBlank {
            request.setValue("Bearer \(server.apiKey.trimmed)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
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
        case .anthropic:
            let request = makeRequest(url: try anthropicURL("/models?limit=100"), method: "GET", timeout: 15)
            let (data, response) = try await session.data(for: request)
            try check(response, data)
            struct Response: Decodable {
                struct Model: Decodable { let id: String }
                let data: [Model]
            }
            return try JSONDecoder().decode(Response.self, from: data).data.map(\.id)
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
        if server.apiType == .anthropic {
            return streamChatViaTurns(messages: messages, options: options)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try buildChatRequest(messages: messages, options: options, compatibilityMode: false)
                    var (bytes, response) = try await session.bytes(for: request)
                    guard var http = response as? HTTPURLResponse else { throw LLMError.badResponse }

                    // 部分服务器 / 模型不认识思考参数或非标准的重复惩罚参数，此时去掉这些参数重试一次
                    // OpenAI 兼容接口还会请求用量统计（stream_options），个别服务器不支持时去掉重试
                    let usesExtensions = server.apiType == .openAI || options.thinking != .auto || options.penalties != nil
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

    /// Anthropic：普通聊天也走统一的 streamTurn（不带工具）
    private func streamChatViaTurns(messages: [RequestMessage], options: GenerationOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let entries = messages.map { $0.role == .system ? AgentEntry.system($0.text) : AgentEntry.message($0) }
                    for try await event in streamTurn(entries: entries, tools: [], options: options) {
                        switch event {
                        case .content(let text):
                            continuation.yield(.content(text))
                        case .reasoning(let text):
                            continuation.yield(.reasoning(text))
                        case .finished(let turn):
                            if let usage = turn.usage {
                                continuation.yield(.usage(usage))
                            }
                            if turn.stopReason == "refusal" {
                                continuation.yield(.content(turn.text.isEmpty ? "（Claude 拒绝回答这个请求。）" : "\n\n（回答被中止：Claude 拒绝继续。）"))
                            }
                        }
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
    func complete(messages: [RequestMessage], options: GenerationOptions) async throws -> (text: String, usage: TokenUsage) {
        var text = ""
        var reasoning = ""
        var usage: TokenUsage?
        for try await event in streamChat(messages: messages, options: options) {
            switch event {
            case .content(let piece): text += piece
            case .reasoning(let piece): reasoning += piece
            case .usage(let value): usage = value
            }
        }
        let finalUsage = usage ?? TokenEstimator.estimateUsage(messages: messages, output: reasoning + text)
        return (ThinkParser.split(text).answer.trimmed, finalUsage)
    }

    // MARK: Context window

    /// 尽量从服务器查询模型的上下文窗口（token）。查不到时返回 nil。
    func detectContextWindow(model: String) async -> Int? {
        switch server.apiType {
        case .anthropic:
            guard let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let json = await fetchJSON(try? anthropicURL("/models/" + encoded)) else { return nil }
            return Self.intValue(json["max_input_tokens"])

        case .ollama:
            // 正在运行的模型：实际使用的上下文长度
            if let json = await fetchJSON(try? ollamaURL("/api/ps")),
               let models = json["models"] as? [[String: Any]],
               let running = models.first(where: { ($0["name"] as? String) == model || ($0["model"] as? String) == model }),
               let length = Self.intValue(running["context_length"]) {
                return length
            }
            // 模型参数里设置的 num_ctx
            if let url = try? ollamaURL("/api/show"),
               let body = try? JSONSerialization.data(withJSONObject: ["model": model]),
               let json = await fetchJSON(url, method: "POST", body: body) {
                if let parameters = json["parameters"] as? String,
                   let line = parameters.split(separator: "\n").first(where: { $0.contains("num_ctx") }),
                   let value = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last.flatMap({ Int($0) }) {
                    return value
                }
            }
            return nil

        case .openAI:
            // vLLM：max_model_len；部分服务：context_length / context_window
            if let json = await fetchJSON(try? openAIURL("/models")),
               let models = json["data"] as? [[String: Any]],
               let entry = models.first(where: { ($0["id"] as? String) == model }) {
                for key in ["max_model_len", "context_length", "context_window", "max_context_length"] {
                    if let value = Self.intValue(entry[key]) { return value }
                }
            }
            var root = normalizedBase
            if root.hasSuffix("/v1") { root.removeLast(3) }
            // llama.cpp：/props
            if let json = await fetchJSON(URL(string: root + "/props")),
               let settings = json["default_generation_settings"] as? [String: Any],
               let value = Self.intValue(settings["n_ctx"]) {
                return value
            }
            // LM Studio：/api/v0/models/{id}
            if let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let json = await fetchJSON(URL(string: root + "/api/v0/models/" + encoded)) {
                for key in ["loaded_context_length", "max_context_length"] {
                    if let value = Self.intValue(json[key]) { return value }
                }
            }
            return nil
        }
    }

    private func fetchJSON(_ url: URL?, method: String = "GET", body: Data? = nil) async -> [String: Any]? {
        guard let url else { return nil }
        let request = makeRequest(url: url, method: method, body: body, timeout: 8)
        guard let result = try? await session.data(for: request),
              let http = result.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any]
    }

    static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int > 0 ? int : nil }
        if let double = value as? Double { return double > 0 ? Int(double) : nil }
        if let string = value as? String, let int = Int(string) { return int > 0 ? int : nil }
        return nil
    }

    /// 解析 OpenAI 兼容接口的 usage 对象
    static func parseOpenAIUsage(_ value: Any?) -> TokenUsage? {
        guard let usage = value as? [String: Any] else { return nil }
        let input = intValue(usage["prompt_tokens"]) ?? 0
        let output = intValue(usage["completion_tokens"]) ?? 0
        guard input > 0 || output > 0 else { return nil }
        let details = usage["prompt_tokens_details"] as? [String: Any]
        let cached = intValue(details?["cached_tokens"]) ?? intValue(usage["prompt_cache_hit_tokens"]) ?? 0
        return TokenUsage(inputTokens: input, outputTokens: output, cachedInputTokens: cached)
    }

    /// 解析 Ollama 结束时的统计
    static func parseOllamaUsage(_ json: [String: Any]) -> TokenUsage? {
        let input = intValue(json["prompt_eval_count"]) ?? 0
        let output = intValue(json["eval_count"]) ?? 0
        guard input > 0 || output > 0 else { return nil }
        return TokenUsage(inputTokens: input, outputTokens: output)
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
            if !compatibilityMode {
                body["stream_options"] = ["include_usage": true]
            }
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

        case .anthropic:
            // Anthropic 由 streamChatViaTurns 处理
            return try buildTurnRequest(
                entries: messages.map { $0.role == .system ? AgentEntry.system($0.text) : AgentEntry.message($0) },
                tools: [],
                options: options,
                compatibilityMode: compatibilityMode
            )
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
            if done, let usage = Self.parseOllamaUsage(json) { events.append(.usage(usage)) }
            return (events, done)
        }

        // OpenAI 兼容：用量统计在最后一个数据块（choices 可能为空）
        if let usage = Self.parseOpenAIUsage(json["usage"]) {
            events.append(.usage(usage))
        }
        if let choices = json["choices"] as? [[String: Any]], let choice = choices.first {
            let delta = (choice["delta"] as? [String: Any]) ?? (choice["message"] as? [String: Any]) ?? [:]
            let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String)
            if let reasoning, !reasoning.isEmpty { events.append(.reasoning(reasoning)) }
            if let content = delta["content"] as? String, !content.isEmpty { events.append(.content(content)) }
            return (events, false)
        }

        return (events, false)
    }
}
