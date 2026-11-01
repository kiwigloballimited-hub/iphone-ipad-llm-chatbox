import Foundation

// MARK: - Server

enum APIType: String, Codable, CaseIterable, Identifiable {
    case openAI
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI 兼容接口"
        case .ollama: return "Ollama 原生接口"
        }
    }

    var hint: String {
        switch self {
        case .openAI:
            return "适用于 LM Studio、llama.cpp、vLLM、Ollama（/v1）等。地址示例：http://192.168.1.10:1234"
        case .ollama:
            return "直接使用 Ollama 的 /api/chat。地址示例：http://192.168.1.10:11434"
        }
    }
}

struct ServerConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = "本地服务器"
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

    var systemPrompt: String { persona.systemPrompt(agentName: name) }

    var thinking: ThinkingLevel {
        get { thinkingLevel ?? .auto }
        set { thinkingLevel = newValue }
    }
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
}

struct Conversation: Codable, Identifiable, Hashable {
    var id = UUID()
    var agentID: UUID
    var title: String = Conversation.defaultTitle
    var messages: [ChatMessage] = []
    var createdAt = Date()
    var updatedAt = Date()

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
}

// MARK: - Persistence container

struct AppData: Codable {
    var servers: [ServerConfig]
    var agents: [Agent]
    var conversations: [Conversation]
    var media: MediaSettings
}
