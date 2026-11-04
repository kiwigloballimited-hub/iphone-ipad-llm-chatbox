import Foundation

// MARK: - Server

enum APIType: String, Codable, CaseIterable, Identifiable {
    case openAI
    case ollama
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return String(localized: "OpenAI 兼容接口")
        case .ollama: return String(localized: "Ollama 原生接口")
        case .anthropic: return String(localized: "Anthropic（Claude）")
        }
    }

    var hint: String {
        switch self {
        case .openAI:
            return String(localized: "适用于 LM Studio、llama.cpp、vLLM、Ollama（/v1）等。地址示例：http://192.168.1.10:1234")
        case .ollama:
            return String(localized: "直接使用 Ollama 的 /api/chat。地址示例：http://192.168.1.10:11434")
        case .anthropic:
            return String(localized: "Claude 官方 API。地址：https://api.anthropic.com，需要填写 API Key。")
        }
    }
}

struct ServerConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = String(localized: "本地服务器")
    var baseURL: String = "http://192.168.1.100:11434"
    var apiType: APIType = .ollama
    var apiKey: String = ""
    var defaultModel: String = ""
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
            parts.append(String(localized: "你的名字是「\(name)」。"))
        }
        let sections: [(String, String)] = [
            (String(localized: "身份"), role),
            (String(localized: "性格"), personality),
            (String(localized: "说话风格"), speakingStyle),
            (String(localized: "背景故事"), background),
            (String(localized: "行为准则"), rules),
            (String(localized: "对话示例"), exampleDialogue),
        ]
        for (title, value) in sections where !value.isBlank {
            parts.append(String(localized: "【\(title)】\n\(value.trimmed)"))
        }
        if parts.count > 1 {
            parts.append(String(localized: "请在整个对话中始终保持以上人格设定。"))
        }
        return parts.joined(separator: "\n\n")
    }
}

struct Agent: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = String(localized: "新助手")
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
    /// 手动指定的上下文窗口（token），nil = 自动检测
    var contextWindowOverride: Int?

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
        case .auto: return String(localized: "自动")
        case .off: return String(localized: "关闭")
        case .low: return String(localized: "低")
        case .medium: return String(localized: "中")
        case .high: return String(localized: "高")
        }
    }

    var detail: String {
        switch self {
        case .auto: return String(localized: "使用模型默认设置")
        case .off: return String(localized: "不思考，直接回答，速度最快")
        case .low: return String(localized: "简单思考")
        case .medium: return String(localized: "适度思考")
        case .high: return String(localized: "深入思考，回答更慢但更严谨")
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
        /// PDF / 文本文件：保存提取出的文字（.txt），作为文字上下文发送
        case document
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
    /// 文档的原始文件名
    var displayName: String?
    var pageCount: Int?
    /// 提取出的文字长度（字符数）
    var textLength: Int?

    /// 图片和视频帧会作为图片发送给模型；文档作为文字发送
    var isVisual: Bool { kind != .document }
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
    /// 生成失败的原因（content 保留已生成的部分，便于从断点继续）
    var errorText: String?
    /// 生成这条回复消耗的 token（可能包含多次请求，例如重试、工具调用）
    var usage: TokenUsage?
    /// 置顶：始终发送给模型，不会被历史窗口丢弃
    var pinned: Bool?
    /// 排除：仍然显示，但不发送给模型
    var excluded: Bool?

    var isPinned: Bool { pinned ?? false }
    var isExcluded: Bool { excluded ?? false }
}

/// Token 用量。服务器没有返回时按字数估算（estimated = true）
struct TokenUsage: Codable, Hashable {
    /// 输入 token（含缓存命中 / 写入的部分）
    var inputTokens = 0
    var outputTokens = 0
    /// 缓存命中（读取）的输入 token
    var cachedInputTokens = 0
    /// 写入缓存的输入 token（Anthropic）
    var cacheWriteTokens = 0
    /// 最后一次请求的输入 / 输出（用于计算当前上下文占用）
    var lastInputTokens = 0
    var lastOutputTokens = 0
    var requests = 0
    var estimated = false

    static let zero = TokenUsage()

    var totalTokens: Int { inputTokens + outputTokens }

    /// 累加另一次请求的用量
    mutating func add(_ other: TokenUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cachedInputTokens += other.cachedInputTokens
        cacheWriteTokens += other.cacheWriteTokens
        if other.inputTokens > 0 || other.outputTokens > 0 {
            lastInputTokens = other.lastInputTokens > 0 ? other.lastInputTokens : other.inputTokens
            lastOutputTokens = other.lastOutputTokens > 0 ? other.lastOutputTokens : other.outputTokens
        }
        requests += max(other.requests, 1)
        estimated = estimated || other.estimated
    }

    init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0, cacheWriteTokens: Int = 0, estimated: Bool = false) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.lastInputTokens = inputTokens
        self.lastOutputTokens = outputTokens
        self.requests = (inputTokens > 0 || outputTokens > 0) ? 1 : 0
        self.estimated = estimated
    }

    // 所有字段都允许缺失，方便以后增加字段
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cachedInputTokens = try c.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        cacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        lastInputTokens = try c.decodeIfPresent(Int.self, forKey: .lastInputTokens) ?? 0
        lastOutputTokens = try c.decodeIfPresent(Int.self, forKey: .lastOutputTokens) ?? 0
        requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        estimated = try c.decodeIfPresent(Bool.self, forKey: .estimated) ?? false
    }
}

/// 模型价格（美元 / 每百万 token）
struct ModelPrice: Codable, Hashable {
    var input: Double
    var output: Double
    /// 缓存命中的输入价格，nil = 输入价格的 10%
    var cachedInput: Double?
    /// 写入缓存的价格，nil = 输入价格的 1.25 倍
    var cacheWrite: Double?

    static let free = ModelPrice(input: 0, output: 0, cachedInput: 0, cacheWrite: 0)
}

enum DisplayCurrency: String, Codable, CaseIterable, Identifiable {
    case usd, gbp, cny

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .usd: return "$"
        case .gbp: return "£"
        case .cny: return "¥"
        }
    }
    var displayName: String {
        switch self {
        case .usd: return String(localized: "美元 USD")
        case .gbp: return String(localized: "英镑 GBP")
        case .cny: return String(localized: "人民币 CNY")
        }
    }
    /// 默认汇率（1 美元 = ?），仅作参考，可在设置中修改
    var defaultRate: Double {
        switch self {
        case .usd: return 1
        case .gbp: return 0.76
        case .cny: return 7.1
        }
    }
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
    /// 后台整理（摘要、记忆提取）消耗的 token
    var backgroundUsage: TokenUsage?
    /// 上下文起点：这个时间之前的消息不再发送给模型（置顶的除外）
    var contextStartsAt: Date?
    /// 最近一次手动调整上下文（置顶 / 排除 / 起点）的时间
    var contextEditedAt: Date?
    /// 分支：来源对话
    var parentID: UUID?
    var parentTitle: String?
    /// 分支：从原对话复制过来的最后一条消息（之后是分支里的新内容）
    var forkPointMessageID: UUID?

    static let defaultTitle = String(localized: "新对话")

    var preview: String {
        guard let last = messages.last(where: { $0.role != .system }) else { return String(localized: "暂无消息") }
        if last.isError, let errorText = last.errorText, ThinkParser.split(last.content).answer.isBlank {
            return "⚠️ " + errorText
        }
        let text = ThinkParser.split(last.content).answer.trimmed
        if !text.isEmpty { return text }
        if let document = last.attachments.first(where: { $0.kind == .document }) {
            return String(localized: "[文档] ") + (document.displayName ?? String(localized: "文档"))
        }
        if !last.attachments.isEmpty { return String(localized: "[\(last.attachments.count) 张图片]") }
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
        case .uniform: return String(localized: "均匀抽取")
        case .interval: return String(localized: "按间隔")
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

    // 网络：断线自动重试
    var autoRetrySetting: Bool?
    var retryLimitSetting: Int?
    var autoRetry: Bool {
        get { autoRetrySetting ?? true }
        set { autoRetrySetting = newValue }
    }
    var retryLimit: Int {
        get { retryLimitSetting ?? 3 }
        set { retryLimitSetting = newValue }
    }

    // 费用显示
    var currencySetting: DisplayCurrency?
    /// 1 美元兑换所选货币的汇率（nil = 默认参考汇率）
    var currencyRateSetting: Double?
    var currency: DisplayCurrency {
        get { currencySetting ?? .usd }
        set {
            currencySetting = newValue
            currencyRateSetting = nil
        }
    }
    var currencyRate: Double {
        get { currencyRateSetting ?? currency.defaultRate }
        set { currencyRateSetting = newValue }
    }

    // iPhone 集成
    var liveActivitiesSetting: Bool?
    /// 语音识别语言，例如 zh-CN / en-GB
    var voiceLocaleSetting: String?
    var liveActivities: Bool {
        get { liveActivitiesSetting ?? true }
        set { liveActivitiesSetting = newValue }
    }
    var voiceLocale: String {
        get { voiceLocaleSetting ?? "zh-CN" }
        set { voiceLocaleSetting = newValue }
    }

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
        case .bing: return String(localized: "必应 Bing")
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .baidu: return String(localized: "百度")
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
    /// 用户自定义的模型价格（按模型名）
    var customPrices: [String: ModelPrice]?
    /// 自动检测到的上下文窗口（键：服务器ID|模型名）
    var contextWindows: [String: Int]?
}
