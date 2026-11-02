import Foundation

// MARK: - Server

enum APIType: String, Codable, CaseIterable, Identifiable {
    case openAI
    case ollama
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI 兼容接口"
        case .ollama: return "Ollama 原生接口"
        case .anthropic: return "Anthropic（Claude）"
        }
    }

    var hint: String {
        switch self {
        case .openAI:
            return "适用于 LM Studio、llama.cpp、vLLM、Ollama（/v1）等。地址示例：http://192.168.1.10:1234"
        case .ollama:
            return "直接使用 Ollama 的 /api/chat。地址示例：http://192.168.1.10:11434"
        case .anthropic:
            return "Claude 官方 API。地址：https://api.anthropic.com，需要填写 API Key。"
        }
    }
}

struct ServerConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = "本地服务器"
    var baseURL: String = "http://192.168.1.100:11434"
    var apiType: APIType = .ollama
    /// 只保存在内存和钥匙串中，不会写入 data.json（见下方自定义 Codable）
    var apiKey: String = ""
    var defaultModel: String = ""
}

// 放在 extension 中以保留自动生成的成员初始化方法。
extension ServerConfig {
    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiType, apiKey, defaultModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerConfig()
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? defaults.id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
        apiType = try container.decodeIfPresent(APIType.self, forKey: .apiType) ?? defaults.apiType
        // 旧版本以明文保存的 API Key：仍然读取，以便迁移到钥匙串
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? defaults.defaultModel
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(apiType, forKey: .apiType)
        try container.encode(defaultModel, forKey: .defaultModel)
        // apiKey 故意不写入，保存在钥匙串中
    }
}

// MARK: - Persona & Agent

/// 独立的人格设定。可以使用结构化字段，也可以直接写自定义系统提示词。
struct Persona: Codable, Hashable {
    var role: String = ""
    var personality: String = ""
    var speakingStyle: String = ""
    var background: String = ""
    var rules: String = ""
    var exampleDialogue: String = ""
    var useCustomPrompt: Bool = false
    var customPrompt: String = ""

    func systemPrompt(agentName: String) -> String {
        if useCustomPrompt {
            return customPrompt.trimmed
        }
        var parts: [String] = []
        let name = agentName.trimmed
        if !name.isEmpty {
            parts.append("你的名字是「\(name)」。")
        }
        let sections: [(String, String)] = [
            ("身份", role),
            ("性格", personality),
            ("说话风格", speakingStyle),
            ("背景故事", background),
            ("行为准则", rules),
            ("对话示例", exampleDialogue),
        ]
        for (title, value) in sections where !value.isBlank {
            parts.append("【\(title)】\n\(value.trimmed)")
        }
        if parts.count > 1 {
            parts.append("请在整个对话中始终保持以上人格设定。")
        }
        return parts.joined(separator: "\n\n")
    }
}

struct Agent: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = "新助手"
    var avatar: String = "🤖"
    var persona = Persona()
    /// 新建对话时由助手先说的话（可选）
    var greeting: String = ""
    /// nil = 使用第一个服务器
    var serverID: UUID?
    /// 空 = 使用服务器的默认模型
    var model: String = ""
    var temperature: Double = 0.7
    /// 0 = 不限制
    var maxTokens: Int = 0
    /// 发送给模型的历史消息条数，0 = 全部
    var contextMessageLimit: Int = 20
    var createdAt = Date()
    /// 思考强度。可选类型，以便兼容旧版本保存的数据（nil = 自动）
    var thinkingLevel: ThinkingLevel?
    /// 是否在对话中使用长期记忆（nil = 开启）
    var memoryEnabledSetting: Bool?
    /// 是否自动从对话中提取记忆（nil = 关闭）
    var autoMemorySetting: Bool?
    /// 超出上下文条数时，是否把早期消息压缩成摘要（nil = 开启）
    var rollingSummarySetting: Bool?
    /// 重复惩罚（nil = 使用服务器 / 模型默认值）
    var penalties: PenaltySettings?
    /// 是否允许使用内置浏览器（工具调用）（nil = 关闭）
    var browserEnabledSetting: Bool?

    var systemPrompt: String { persona.systemPrompt(agentName: name) }

    var thinking: ThinkingLevel {
        get { thinkingLevel ?? .auto }
        set { thinkingLevel = newValue }
    }

    var memoryEnabled: Bool {
        get { memoryEnabledSetting ?? true }
        set { memoryEnabledSetting = newValue }
    }

    var autoMemory: Bool {
        get { autoMemorySetting ?? false }
        set { autoMemorySetting = newValue }
    }

    var rollingSummary: Bool {
        get { rollingSummarySetting ?? true }
        set { rollingSummarySetting = newValue }
    }

    var browserEnabled: Bool {
        get { browserEnabledSetting ?? false }
        set { browserEnabledSetting = newValue }
    }

    /// 编辑界面使用：开启自定义后读写具体数值
    var penaltyValues: PenaltySettings {
        get { penalties ?? PenaltySettings() }
        set { penalties = newValue }
    }
}

/// 重复惩罚相关参数
struct PenaltySettings: Codable, Hashable {
    /// 重复惩罚（llama.cpp / Ollama 的 repeat_penalty，vLLM 的 repetition_penalty）。1.0 = 不惩罚
    var repeatPenalty: Double = 1.1
    /// 参与重复判断的最近 token 数（Ollama / llama.cpp 的 repeat_last_n）
    var repeatLastN: Int = 64
    /// 频率惩罚（OpenAI 标准参数），出现次数越多惩罚越重。0 = 不惩罚
    var frequencyPenalty: Double = 0
    /// 存在惩罚（OpenAI 标准参数），只要出现过就惩罚，鼓励换话题。0 = 不惩罚
    var presencePenalty: Double = 0
}

// MARK: - Long-term memory

/// 助手的一条长期记忆（跨会话）
struct MemoryItem: Codable, Identifiable, Hashable {
    enum Source: String, Codable {
        case manual   // 用户手动添加
        case extracted // 用户确认后从对话中提取
        case auto     // 自动提取
    }

    var id = UUID()
    var agentID: UUID
    var text: String
    var source: Source = .manual
    var createdAt = Date()
    var conversationID: UUID?
}

/// 推理模型的思考强度
enum ThinkingLevel: String, Codable, CaseIterable, Identifiable {
    /// 不发送任何参数，由模型 / 服务器默认决定
    case auto
    case off
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .off: return "关闭"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "使用模型默认设置"
        case .off: return "不思考，直接回答，速度最快"
        case .low: return "简单思考"
        case .medium: return "适度思考"
        case .high: return "深入思考，回答更慢但更严谨"
        }
    }
}

// MARK: - Chat

enum Role: String, Codable {
    case system, user, assistant
}

struct Attachment: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case image
        case videoFrame
    }

    var id = UUID()
    var kind: Kind
    /// 压缩后的 JPEG 文件名（保存在 Application Support/LocalAIChat/Attachments）
    var fileName: String
    var width: Int
    var height: Int
    var byteCount: Int
    var originalByteCount: Int
    /// 视频帧的时间点（秒）
    var timestamp: Double?
    /// 同一段视频抽出的帧共享同一个 groupID
    var videoGroupID: UUID?
    var videoDuration: Double?
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id = UUID()
    var role: Role
    var content: String
    var reasoning: String = ""
    var attachments: [Attachment] = []
    var createdAt = Date()
    var isError: Bool = false
    var modelName: String?
    /// 工具调用步骤（浏览器操作等）
    var steps: [AgentStep]?
}

/// 助手执行的一个工具步骤，显示在消息气泡里
struct AgentStep: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        case running, done, failed, denied
    }

    var id = UUID()
    var icon: String
    var title: String
    var status: Status = .running
}

struct Conversation: Codable, Identifiable, Hashable {
    var id = UUID()
    var agentID: UUID
    var title: String = Conversation.defaultTitle
    var messages: [ChatMessage] = []
    var createdAt = Date()
    var updatedAt = Date()
    /// 早期消息的滚动摘要
    var summary: String?
    /// 摘要已覆盖到的消息时间（含）
    var summaryCoversUntil: Date?
    /// 自动记忆已处理到的消息时间（含）
    var memoryExtractedUntil: Date?

    static let defaultTitle = "新对话"

    var preview: String {
        guard let last = messages.last(where: { $0.role != .system }) else { return "暂无消息" }
        let text = ThinkParser.split(last.content).answer.trimmed
        if !text.isEmpty { return text }
        if !last.attachments.isEmpty { return "[\(last.attachments.count) 张图片]" }
        return "…"
    }
}

// MARK: - Media settings

enum FrameSamplingMode: String, Codable, CaseIterable, Identifiable {
    case uniform
    case interval

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .uniform: return "均匀抽取"
        case .interval: return "按间隔"
        }
    }
}

struct MediaSettings: Codable, Hashable {
    // 图片压缩
    /// 最长边像素，0 = 保持原尺寸
    var imageMaxDimension: Int = 1280
    var imageQuality: Double = 0.75
    /// 单张图片大小上限（KB），0 = 不限
    var imageMaxKB: Int = 500

    // 视频抽帧
    var videoFrameMode: FrameSamplingMode = .uniform
    var videoFrameCount: Int = 8
    var videoFrameInterval: Double = 2.0
    var videoMaxFrames: Int = 16
    var videoFrameMaxDimension: Int = 768
    var videoFrameQuality: Double = 0.7

    // 上下文
    /// 是否在历史消息中重复发送图片（关闭可大幅减少请求体积）
    var sendHistoryImages: Bool = false

    // 浏览器
    var searchEngineSetting: SearchEngine?
    var searchEngine: SearchEngine {
        get { searchEngineSetting ?? .bing }
        set { searchEngineSetting = newValue }
    }
}

enum SearchEngine: String, Codable, CaseIterable, Identifiable {
    case bing, google, duckDuckGo, baidu

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bing: return "必应 Bing"
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .baidu: return "百度"
        }
    }

    func searchURL(_ query: String) -> URL? {
        var components: URLComponents?
        switch self {
        case .bing: components = URLComponents(string: "https://www.bing.com/search")
        case .google: components = URLComponents(string: "https://www.google.com/search")
        case .duckDuckGo: components = URLComponents(string: "https://html.duckduckgo.com/html/")
        case .baidu: components = URLComponents(string: "https://www.baidu.com/s")
        }
        components?.queryItems = [URLQueryItem(name: self == .baidu ? "wd" : "q", value: query)]
        return components?.url
    }
}

// MARK: - Persistence container

struct AppData: Codable {
    var servers: [ServerConfig]
    var agents: [Agent]
    var conversations: [Conversation]
    var media: MediaSettings
    var memories: [MemoryItem]?
}
