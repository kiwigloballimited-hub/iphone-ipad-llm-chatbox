import AppIntents
import Foundation

// MARK: - 助手（供 Siri / 快捷指令选择）

struct AgentEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "助手"
    static var defaultQuery = AgentQuery()

    var id: UUID
    var name: String
    var avatar: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(avatar) \(name)")
    }

    init(_ agent: Agent) {
        id = agent.id
        name = agent.name
        avatar = agent.avatar
    }
}

struct AgentQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [AgentEntity] {
        AppStore.shared.agents.filter { identifiers.contains($0.id) }.map(AgentEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [AgentEntity] {
        AppStore.shared.agents
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(AgentEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [AgentEntity] {
        AppStore.shared.agents.map(AgentEntity.init)
    }
}

// MARK: - 问助手（后台运行，直接返回回答）

struct AskAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "问助手"
    static var description = IntentDescription("向 AI 助手提问并直接得到回答，Siri 会读出来；回答也可以在快捷指令里继续使用。问答会保存在 App 的「Siri 与快捷指令」对话里。")

    @Parameter(title: "助手", description: "不选则使用第一个助手")
    var agent: AgentEntity?

    @Parameter(title: "问题", requestValueDialog: "你想问什么？")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("问 \(\.$agent)：\(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = try await AppStore.shared.askFromIntent(agentID: agent?.id, question: question)
        let spoken = answer.count > 600 ? String(answer.prefix(600)) + "……（完整回答请在 App 中查看）" : answer
        return .result(value: answer, dialog: "\(spoken)")
    }
}

// MARK: - 打开 App 的操作

struct NewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "新对话"
    static var description = IntentDescription("打开 App 并和某个助手开始新对话。")
    static var openAppWhenRun = true

    @Parameter(title: "助手", description: "不选则使用第一个助手")
    var agent: AgentEntity?

    @Parameter(title: "直接语音提问", default: false)
    var voice: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("和 \(\.$agent) 开始新对话") {
            \.$voice
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppStore.shared.openNewChat(agentID: agent?.id, voice: voice)
        return .result()
    }
}

/// 适合设置到「操作按钮」：按一下就开始说话
struct VoiceAskIntent: AppIntent {
    static var title: LocalizedStringResource = "语音提问"
    static var description = IntentDescription("打开 App，直接开始语音输入，说完即可发送给助手。适合设置到 iPhone 的操作按钮。")
    static var openAppWhenRun = true

    @Parameter(title: "助手", description: "不选则使用第一个助手")
    var agent: AgentEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("用语音问 \(\.$agent)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppStore.shared.openNewChat(agentID: agent?.id, voice: true)
        return .result()
    }
}

/// 把文字 / 图片发给助手。在快捷指令里勾选「在共享表单中显示」，就可以从任何 App 的分享菜单使用。
struct SendToAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "发送给助手"
    static var description = IntentDescription("把文字或图片发送给 AI 助手处理，并打开 App 查看回复。配合快捷指令的「在共享表单中显示」，可以从 Safari 等 App 的分享菜单直接发送。")
    static var openAppWhenRun = true

    @Parameter(title: "助手", description: "不选则使用第一个助手")
    var agent: AgentEntity?

    @Parameter(title: "文字")
    var text: String?

    @Parameter(title: "图片", supportedTypeIdentifiers: ["public.image"])
    var images: [IntentFile]?

    @Parameter(title: "要求", description: "例如：翻译成中文、总结要点、解释这张图片")
    var instruction: String?

    @Parameter(title: "立即发送", default: true)
    var sendImmediately: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$text) 发送给 \(\.$agent)") {
            \.$images
            \.$instruction
            \.$sendImmediately
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = AppStore.shared
        var attachments: [Attachment] = []
        for file in images ?? [] {
            if let attachment = await AttachmentFactory.image(from: file.data, settings: store.media) {
                attachments.append(attachment)
            }
        }
        var parts: [String] = []
        if let instruction, !instruction.isBlank { parts.append(instruction.trimmed) }
        if let text, !text.isBlank { parts.append(text.trimmed) }
        store.openNewChat(
            agentID: agent?.id,
            text: parts.joined(separator: "\n\n"),
            attachments: attachments,
            sendImmediately: sendImmediately
        )
        return .result()
    }
}

// MARK: - Siri 短语 / 快捷指令 App 里的现成操作

struct LocalAIShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .purple

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAgentIntent(),
            phrases: [
                "问\(.applicationName)",
                "用\(.applicationName)提问",
                "问\(.applicationName)的\(\.$agent)",
            ],
            shortTitle: "问助手",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: VoiceAskIntent(),
            phrases: [
                "用\(.applicationName)语音提问",
                "\(.applicationName)语音提问",
            ],
            shortTitle: "语音提问",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: NewChatIntent(),
            phrases: [
                "在\(.applicationName)新建对话",
                "打开\(.applicationName)的\(\.$agent)",
            ],
            shortTitle: "新对话",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: SendToAgentIntent(),
            phrases: [
                "发送给\(.applicationName)",
            ],
            shortTitle: "发送给助手",
            systemImageName: "paperplane"
        )
    }
}
