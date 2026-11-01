import SwiftUI

struct AgentEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var agent: Agent
    let isNew: Bool

    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelError: String?
    @State private var showPromptPreview = false

    private let avatarChoices = ["🤖", "✍️", "👩‍🏫", "👨‍🏫", "🧑‍💻", "🇬🇧", "🔍", "🐱", "🦊", "🐼", "🌸", "📚", "🎨", "🧙‍♀️", "🧑‍⚕️", "🍵", "🌙", "⭐️"]

    init(agent: Agent, isNew: Bool) {
        _agent = State(initialValue: agent)
        self.isNew = isNew
    }

    var body: some View {
        NavigationStack {
            Form {
                basicSection
                modelSection
                thinkingSection
                personaSection
                greetingSection
                parameterSection
                Section {
                    Button("预览系统提示词", systemImage: "doc.text.magnifyingglass") {
                        showPromptPreview = true
                    }
                } footer: {
                    Text("系统提示词会在每次对话时发送给模型，决定助手的人格和行为。")
                }
            }
            .navigationTitle(isNew ? "新建助手" : "编辑助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        agent.name = agent.name.trimmed
                        store.upsertAgent(agent)
                        dismiss()
                    }
                    .disabled(agent.name.isBlank)
                }
            }
            .sheet(isPresented: $showPromptPreview) {
                PromptPreview(prompt: agent.systemPrompt)
            }
        }
    }

    // MARK: Sections

    private var basicSection: some View {
        Section("基本信息") {
            HStack(spacing: 12) {
                TextField("🤖", text: $agent.avatar)
                    .font(.system(size: 34))
                    .multilineTextAlignment(.center)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(Color(.secondarySystemBackground)))
                    .onChange(of: agent.avatar) { _, value in
                        // 只保留最新输入的一个字符（emoji）
                        if value.count > 1, let latest = value.last.map(String.init) {
                            agent.avatar = latest
                        }
                    }
                TextField("助手名称", text: $agent.name)
                    .font(.title3)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(avatarChoices, id: \.self) { emoji in
                        Text(emoji)
                            .font(.title2)
                            .frame(width: 40, height: 40)
                            .background(
                                Circle().fill(agent.avatar == emoji ? Color.accentColor.opacity(0.25) : Color.clear)
                            )
                            .onTapGesture { agent.avatar = emoji }
                    }
                }
            }
            Menu {
                ForEach(PersonaTemplates.all) { template in
                    Button("\(template.avatar) \(template.name)") {
                        agent.persona = template.persona
                        agent.greeting = template.greeting
                        agent.temperature = template.temperature
                        if agent.name.isBlank || agent.name == Agent().name { agent.name = template.name }
                        agent.avatar = template.avatar
                    }
                }
            } label: {
                Label("套用人格模板", systemImage: "wand.and.stars")
            }
        }
    }

    private var modelSection: some View {
        Section {
            Picker("服务器", selection: $agent.serverID) {
                Text("默认（\(store.servers.first?.name ?? "无")）").tag(UUID?.none)
                ForEach(store.servers) { server in
                    Text(server.name).tag(Optional(server.id))
                }
            }
            HStack {
                TextField(defaultModelPlaceholder, text: $agent.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                if isLoadingModels {
                    ProgressView()
                } else {
                    Menu {
                        if availableModels.isEmpty {
                            Text("点击「获取模型列表」")
                        }
                        ForEach(availableModels, id: \.self) { name in
                            Button(name) { agent.model = name }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                }
            }
            Button("从服务器获取模型列表", systemImage: "arrow.down.circle") {
                Task { await fetchModels() }
            }
            .disabled(isLoadingModels || selectedServer == nil)
            if let modelError {
                Text(modelError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("模型")
        } footer: {
            Text("需要识别图片 / 视频时，请选择支持视觉的模型，例如 qwen2.5vl、gemma3、llama3.2-vision、minicpm-v。")
        }
    }

    private var personaSection: some View {
        Section {
            Toggle("直接编写系统提示词", isOn: $agent.persona.useCustomPrompt)
            if agent.persona.useCustomPrompt {
                PersonaField(title: "系统提示词", placeholder: "完整描述助手的人格、背景和行为规则…", text: $agent.persona.customPrompt, lines: 6...20)
            } else {
                PersonaField(title: "身份 / 角色", placeholder: "例如：一位温柔耐心的小学语文老师", text: $agent.persona.role)
                PersonaField(title: "性格", placeholder: "例如：开朗、细心、爱鼓励人", text: $agent.persona.personality)
                PersonaField(title: "说话风格", placeholder: "例如：简短亲切，偶尔用 emoji，多用比喻", text: $agent.persona.speakingStyle)
                PersonaField(title: "背景故事", placeholder: "人物的经历、所处的世界观、与用户的关系…", text: $agent.persona.background, lines: 2...10)
                PersonaField(title: "行为准则", placeholder: "必须做什么、不能做什么，例如：只用英语回答；不要直接给出答案", text: $agent.persona.rules, lines: 2...10)
                PersonaField(title: "对话示例（可选）", placeholder: "用户：……\n助手：……", text: $agent.persona.exampleDialogue, lines: 2...10)
            }
        } header: {
            Text("人格设定")
        } footer: {
            Text("每个助手的人格设定和对话记录相互独立。")
        }
    }

    private var greetingSection: some View {
        Section {
            TextField("新对话时助手主动说的第一句话（可选）", text: $agent.greeting, axis: .vertical)
                .lineLimit(1...5)
        } header: {
            Text("开场白")
        }
    }

    private var thinkingSection: some View {
        Section {
            Picker("思考强度", selection: $agent.thinking) {
                ForEach(ThinkingLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
            Text(agent.thinking.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text("思考强度")
        } footer: {
            Text("适用于会「思考」的推理模型，如 Qwen3、DeepSeek-R1、gpt-oss。「低 / 中 / 高」三档只对支持分级的模型（如 gpt-oss）有区别，其他模型选这三档都等同于「开启思考」。如果模型不支持思考，App 会自动去掉这个参数重新请求。")
        }
    }

    private var parameterSection: some View {
        Section("生成参数") {
            VStack(alignment: .leading) {
                HStack {
                    Text("温度（创造力）")
                    Spacer()
                    Text(agent.temperature, format: .number.precision(.fractionLength(2)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $agent.temperature, in: 0...2, step: 0.05)
                HStack {
                    Text("严谨").font(.caption2)
                    Spacer()
                    Text("发散").font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            Stepper(value: $agent.maxTokens, in: 0...32768, step: 256) {
                HStack {
                    Text("最大回复长度")
                    Spacer()
                    Text(agent.maxTokens == 0 ? "不限" : "\(agent.maxTokens)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Stepper(value: $agent.contextMessageLimit, in: 0...200, step: 2) {
                HStack {
                    Text("记忆的历史消息")
                    Spacer()
                    Text(agent.contextMessageLimit == 0 ? "全部" : "\(agent.contextMessageLimit) 条")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: Helpers

    private var selectedServer: ServerConfig? {
        if let id = agent.serverID, let server = store.servers.first(where: { $0.id == id }) { return server }
        return store.servers.first
    }

    private var defaultModelPlaceholder: String {
        if let model = selectedServer?.defaultModel, !model.isBlank {
            return "默认：\(model)"
        }
        return "模型名称，例如 qwen2.5vl:7b"
    }

    private func fetchModels() async {
        guard let server = selectedServer else { return }
        isLoadingModels = true
        modelError = nil
        defer { isLoadingModels = false }
        do {
            availableModels = try await LLMClient(server: server).listModels()
            if availableModels.isEmpty { modelError = "服务器上没有可用的模型。" }
        } catch {
            modelError = LLMError.friendlyDescription(error)
        }
    }
}

private struct PersonaField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var lines: ClosedRange<Int> = 1...6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(lines)
        }
        .padding(.vertical, 2)
    }
}

private struct PromptPreview: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(prompt.isEmpty ? "（空）" : prompt)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("系统提示词预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("复制", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = prompt
                    }
                }
            }
        }
    }
}
