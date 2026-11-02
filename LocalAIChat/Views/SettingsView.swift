import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var editingServer: ServerConfig?
    @State private var showDeleteAll = false
    @State private var showClearBrowser = false

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                Section {
                    ForEach(store.servers) { server in
                        Button {
                            editingServer = server
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).foregroundStyle(Color.primary)
                                Text("\(server.apiType.displayName) · \(server.baseURL)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { store.servers[$0].id }.forEach(store.deleteServer)
                    }
                    Button("添加服务器", systemImage: "plus") {
                        editingServer = ServerConfig(name: "服务器 \(store.servers.count + 1)")
                    }
                } header: {
                    Text("AI 服务器")
                } footer: {
                    Text("支持 Ollama、LM Studio、llama.cpp、vLLM 等本地服务。请确保 iPhone / iPad 与服务器连接在同一个局域网。")
                }

                Section {
                    Picker("最长边", selection: $store.media.imageMaxDimension) {
                        ForEach([512, 768, 1024, 1280, 1600, 2048], id: \.self) { value in
                            Text("\(value) px").tag(value)
                        }
                        Text("不缩放").tag(0)
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("JPEG 质量")
                            Spacer()
                            Text("\(Int(store.media.imageQuality * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $store.media.imageQuality, in: 0.3...1.0, step: 0.05)
                    }
                    Picker("单张大小上限", selection: $store.media.imageMaxKB) {
                        Text("不限").tag(0)
                        ForEach([150, 300, 500, 1000, 2000], id: \.self) { value in
                            Text(value >= 1000 ? "\(value / 1000) MB" : "\(value) KB").tag(value)
                        }
                    }
                } header: {
                    Text("图片压缩")
                } footer: {
                    Text("图片会先缩小到最长边，再按质量压缩为 JPEG；若仍超过大小上限，会自动继续降低质量和尺寸。")
                }

                Section {
                    Picker("抽帧方式", selection: $store.media.videoFrameMode) {
                        ForEach(FrameSamplingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    if store.media.videoFrameMode == .uniform {
                        Stepper("帧数：\(store.media.videoFrameCount)", value: $store.media.videoFrameCount, in: 1...32)
                    } else {
                        Stepper(value: $store.media.videoFrameInterval, in: 0.5...60, step: 0.5) {
                            Text("每 \(store.media.videoFrameInterval, format: .number.precision(.fractionLength(1))) 秒一帧")
                        }
                        Stepper("最多：\(store.media.videoMaxFrames) 帧", value: $store.media.videoMaxFrames, in: 1...64)
                    }
                    Picker("帧分辨率（最长边）", selection: $store.media.videoFrameMaxDimension) {
                        ForEach([384, 512, 768, 1024, 1280], id: \.self) { value in
                            Text("\(value) px").tag(value)
                        }
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("帧 JPEG 质量")
                            Spacer()
                            Text("\(Int(store.media.videoFrameQuality * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $store.media.videoFrameQuality, in: 0.3...1.0, step: 0.05)
                    }
                } header: {
                    Text("视频抽帧（默认值）")
                } footer: {
                    Text("选择视频后会按这里的设置解码抽帧，也可以在抽帧界面临时调整。")
                }

                Section {
                    Picker("搜索引擎", selection: $store.media.searchEngine) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    Button("清除浏览器数据（Cookie、登录状态）", role: .destructive) {
                        showClearBrowser = true
                    }
                } header: {
                    Text("浏览器")
                } footer: {
                    Text("内置浏览器的登录状态会保留，下次 AI 访问同一网站时仍然是登录状态。")
                }

                Section {
                    Toggle("历史消息中重复发送图片", isOn: $store.media.sendHistoryImages)
                } header: {
                    Text("上下文")
                } footer: {
                    Text("关闭时，只有最近一条带图片的消息会附带图片，之前的图片以文字占位，可以大幅减少请求体积和等待时间。")
                }

                Section {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    LabeledContent("助手数量", value: "\(store.agents.count)")
                    LabeledContent("对话数量", value: "\(store.conversations.count)")
                    Button("删除所有对话", role: .destructive) { showDeleteAll = true }
                } header: {
                    Text("关于")
                } footer: {
                    Text("所有数据仅保存在本机，不会上传到除你的服务器以外的任何地方。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: store.media) { _, _ in store.save() }
            .sheet(item: $editingServer) { server in
                ServerEditorView(server: server)
            }
            .confirmationDialog("清除内置浏览器的所有 Cookie 和网站数据？已登录的网站需要重新登录。", isPresented: $showClearBrowser, titleVisibility: .visible) {
                Button("清除", role: .destructive) {
                    Task { await BrowserSession.clearAllData() }
                }
            }
            .confirmationDialog("删除所有助手的全部对话？此操作无法撤销。", isPresented: $showDeleteAll, titleVisibility: .visible) {
                Button("全部删除", role: .destructive) { store.deleteAllConversations() }
            }
        }
    }
}

struct ServerEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var server: ServerConfig
    @State private var testState: TestState = .idle
    @State private var models: [String] = []

    struct Preset {
        let name: String
        let url: String
        let type: APIType
        let model: String
    }

    static let presets: [Preset] = [
        Preset(name: "Ollama（本地）", url: "http://192.168.1.100:11434", type: .ollama, model: ""),
        Preset(name: "LM Studio（本地）", url: "http://192.168.1.100:1234", type: .openAI, model: ""),
        Preset(name: "DeepSeek", url: "https://api.deepseek.com", type: .openAI, model: "deepseek-chat"),
        Preset(name: "Anthropic Claude", url: "https://api.anthropic.com", type: .anthropic, model: "claude-opus-5-5"),
    ]

    enum TestState: Equatable {
        case idle
        case testing
        case success(Int)
        case failure(String)
    }

    init(server: ServerConfig) {
        _server = State(initialValue: server)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $server.name)
                    TextField("http://192.168.1.10:11434", text: $server.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Picker("接口类型", selection: $server.apiType) {
                        ForEach(APIType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                } header: {
                    Text("服务器")
                } footer: {
                    Text(server.apiType.hint)
                }

                Section {
                    Menu {
                        ForEach(Self.presets, id: \.name) { preset in
                            Button(preset.name) {
                                server.name = preset.name
                                server.baseURL = preset.url
                                server.apiType = preset.type
                                server.defaultModel = preset.model
                                testState = .idle
                                models = []
                            }
                        }
                    } label: {
                        Label("快速填写常用服务", systemImage: "wand.and.stars")
                    }
                }

                Section {
                    SecureField(server.apiType == .anthropic || server.baseURL.contains("deepseek") ? "API Key（必填）" : "API Key（本地服务一般不需要）", text: $server.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("认证（可选）")
                } footer: {
                    Text("API Key 加密保存在本机的系统钥匙串中，不会写入聊天数据文件。")
                }

                Section {
                    HStack {
                        TextField("例如 qwen2.5vl:7b", text: $server.defaultModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        if !models.isEmpty {
                            Menu {
                                ForEach(models, id: \.self) { name in
                                    Button(name) { server.defaultModel = name }
                                }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                            }
                        }
                    }
                } header: {
                    Text("默认模型")
                } footer: {
                    Text("助手没有单独指定模型时使用这个模型。")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Label("测试连接并获取模型", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if testState == .testing { ProgressView() }
                        }
                    }
                    .disabled(testState == .testing || server.baseURL.isBlank)

                    switch testState {
                    case .success(let count):
                        Label("连接成功，找到 \(count) 个模型", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    default:
                        EmptyView()
                    }
                }

                if store.servers.contains(where: { $0.id == server.id }) {
                    Section {
                        Button("删除服务器", role: .destructive) {
                            store.deleteServer(server.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(server.name.isBlank ? "服务器" : server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        server.name = server.name.isBlank ? "本地服务器" : server.name.trimmed
                        server.baseURL = server.baseURL.trimmed
                        store.upsertServer(server)
                        dismiss()
                    }
                    .disabled(server.baseURL.isBlank)
                }
            }
        }
    }

    private func test() async {
        testState = .testing
        do {
            models = try await LLMClient(server: server).listModels()
            testState = .success(models.count)
            if server.defaultModel.isBlank, let first = models.first {
                server.defaultModel = first
            }
        } catch {
            testState = .failure(LLMError.friendlyDescription(error))
        }
    }
}
