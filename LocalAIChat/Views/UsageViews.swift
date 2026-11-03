import SwiftUI

/// 常用的上下文窗口大小
let contextWindowPresets: [(label: String, value: Int)] = [
    ("4K", 4_096), ("8K", 8_192), ("16K", 16_384), ("32K", 32_768), ("64K", 65_536),
    ("128K", 131_072), ("200K", 200_000), ("256K", 262_144), ("1M", 1_000_000),
]

private func contextColor(_ fraction: Double) -> Color {
    fraction < 0.6 ? .green : (fraction < 0.85 ? .orange : .red)
}

@MainActor
private func costText(_ stats: SessionStats, store: AppStore) -> String? {
    if stats.isFree { return "免费" }
    guard let cost = stats.cost else { return nil }
    return (stats.estimated ? "≈" : "") + store.formatCost(cost) + (stats.costIncomplete ? "+" : "")
}

// MARK: - 输入框上方的用量条

struct UsageStrip: View {
    @Environment(AppStore.self) private var store
    let stats: SessionStats

    var body: some View {
        HStack(spacing: 6) {
            if let fraction = stats.contextFraction {
                ContextGauge(fraction: fraction)
                    .frame(width: 12, height: 12)
                Text("上下文 \(Int((fraction * 100).rounded()))%")
                    .foregroundStyle(fraction >= 0.85 ? contextColor(fraction) : Color.secondary)
            } else {
                Image(systemName: "text.alignleft")
                Text("上下文 \(stats.contextEstimated ? "≈" : "")\(AppStore.formatTokens(stats.contextUsed))")
            }
            Text("·")
            Text("\(stats.estimated ? "≈" : "")\(AppStore.formatTokens(stats.totalTokens)) tokens")
            if let cost = costText(stats, store: store) {
                Text("·")
                Text(cost)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up")
                .font(.system(size: 8, weight: .semibold))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看用量与费用详情")
    }
}

/// 上下文占用的小圆环
struct ContextGauge: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(contextColor(fraction), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - 详情

struct UsageDetailSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID
    let draft: String

    var body: some View {
        NavigationStack {
            Group {
                if let conversation = store.conversation(id: conversationID),
                   let agent = store.agent(id: conversation.agentID),
                   let stats = store.sessionStats(for: conversationID, draft: draft) {
                    content(agent: agent, stats: stats)
                } else {
                    ContentUnavailableView("没有数据", systemImage: "chart.bar")
                }
            }
            .navigationTitle("用量与费用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func content(agent: Agent, stats: SessionStats) -> some View {
        let model = store.effectiveModel(for: agent)
        let lookup = store.price(for: model, server: store.server(for: agent))

        return Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("当前占用")
                        Spacer()
                        Text(contextSummary(stats))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let fraction = stats.contextFraction {
                        ProgressView(value: fraction)
                            .tint(contextColor(fraction))
                    }
                }
                LabeledContent("上下文窗口") {
                    Text(stats.contextWindow.map { "\(AppStore.formatTokens($0))（\(stats.contextSource)）" } ?? "未知")
                }
                Picker("手动设置窗口", selection: Binding(
                    get: { agent.contextWindowOverride },
                    set: { value in
                        var updated = agent
                        updated.contextWindowOverride = value
                        store.upsertAgent(updated)
                    }
                )) {
                    Text("自动检测").tag(Int?.none)
                    ForEach(contextWindowPresets, id: \.value) { preset in
                        Text(preset.label).tag(Optional(preset.value))
                    }
                }
                if agent.contextWindowOverride == nil {
                    Button("重新检测", systemImage: "arrow.clockwise") {
                        Task { await store.detectContextWindowIfNeeded(for: agent, force: true) }
                    }
                }
                if let fraction = stats.contextFraction, fraction >= 0.85 {
                    Label("上下文快满了。超出部分模型会看不到；可以开新对话，或在助手设置里减少「记忆的历史消息」条数（开启长对话摘要时，早期内容会被压缩保留）。", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("上下文")
            } footer: {
                Text("占用 = 下一次请求大约要发送给模型的内容（人格设定、记忆、摘要、历史消息、正在输入的文字）。Ollama 的实际窗口取决于服务器设置，检测不到时请手动选择。")
            }

            Section {
                row("输入", stats.usage.inputTokens, estimated: stats.usage.estimated)
                if stats.usage.cachedInputTokens > 0 {
                    row("　其中缓存命中", stats.usage.cachedInputTokens, estimated: false)
                }
                row("输出（含思考）", stats.usage.outputTokens, estimated: stats.usage.estimated)
                if stats.streamingTokens > 0 {
                    row("正在生成", stats.streamingTokens, estimated: true)
                }
                if stats.background.totalTokens > 0 {
                    row("后台整理（摘要 / 记忆）", stats.background.totalTokens, estimated: stats.background.estimated)
                }
                row("合计", stats.totalTokens, estimated: stats.estimated)
                    .fontWeight(.semibold)
                LabeledContent("请求次数", value: "\(stats.usage.requests + stats.background.requests)")
            } header: {
                Text("本次对话用量")
            } footer: {
                if stats.estimated {
                    Text("带「≈」的数字是按字数估算的（服务器没有返回用量，或回复还没有结束）。")
                }
            }

            Section {
                LabeledContent("预估费用") {
                    Text(costText(stats, store: store) ?? "未知（没有价格）")
                        .fontWeight(.semibold)
                }
                LabeledContent("模型", value: model.isEmpty ? "未设置" : model)
                LabeledContent("价格来源", value: lookup.source.label)
                if let price = lookup.price, price != .free {
                    LabeledContent("输入 / 输出", value: "$\(Self.format(price.input)) / $\(Self.format(price.output))")
                    if let cached = price.cachedInput {
                        LabeledContent("缓存命中", value: "$\(Self.format(cached))")
                    }
                }
                if !model.isEmpty {
                    NavigationLink("修改这个模型的价格") {
                        PriceEditorView(model: model, server: store.server(for: agent))
                    }
                }
            } header: {
                Text("费用")
            } footer: {
                Text("价格单位：美元 / 每百万 token。费用 = token 数 × 单价，仅供参考，实际以服务商账单为准。显示货币和汇率可在「设置 › 费用估算」中修改。")
            }
        }
    }

    private func contextSummary(_ stats: SessionStats) -> String {
        let used = (stats.contextEstimated ? "≈" : "") + AppStore.formatTokens(stats.contextUsed)
        guard let window = stats.contextWindow, let fraction = stats.contextFraction else { return used }
        return "\(used) / \(AppStore.formatTokens(window))（\(Int((fraction * 100).rounded()))%）"
    }

    private func row(_ title: String, _ value: Int, estimated: Bool) -> some View {
        LabeledContent(title) {
            Text((estimated ? "≈" : "") + value.formatted())
                .monospacedDigit()
        }
    }

    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)))
    }
}

// MARK: - 模型价格

struct ModelPricesView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let models = store.modelsInUse()
        List {
            Section {
                if models.isEmpty {
                    Text("还没有使用任何模型").foregroundStyle(.secondary)
                }
                ForEach(models, id: \.model) { entry in
                    let lookup = store.price(for: entry.model, server: entry.server)
                    NavigationLink {
                        PriceEditorView(model: entry.model, server: entry.server)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.model)
                                .font(.body.monospaced())
                                .lineLimit(1)
                            Text(summary(lookup))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("内置了 Claude 的官方价格和 DeepSeek 的参考价格；本地服务器上的模型默认免费。价格单位：美元 / 每百万 token。")
            }
        }
        .navigationTitle("模型价格")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func summary(_ lookup: (price: ModelPrice?, source: PriceSource)) -> String {
        guard let price = lookup.price else { return lookup.source.label }
        if price == .free { return lookup.source.label }
        return "输入 $\(UsageDetailSheet.format(price.input)) · 输出 $\(UsageDetailSheet.format(price.output)) · \(lookup.source.label)"
    }
}

struct PriceEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let model: String
    let server: ServerConfig?

    @State private var input: Double = 0
    @State private var output: Double = 0
    @State private var cached: Double = 0
    @State private var loaded = false

    var body: some View {
        let lookup = store.price(for: model, server: server)
        Form {
            Section {
                LabeledContent("模型", value: model)
                LabeledContent("当前", value: lookup.source.label)
            }
            Section {
                priceField("输入", value: $input)
                priceField("输出", value: $output)
                priceField("缓存命中的输入", value: $cached)
            } header: {
                Text("价格（美元 / 每百万 token）")
            } footer: {
                Text("在服务商的价格页面查看最新价格。思考（推理）部分按输出价格计费。")
            }
            Section {
                Button("保存为自定义价格") {
                    store.setCustomPrice(ModelPrice(input: input, output: output, cachedInput: cached), for: model)
                    dismiss()
                }
                Button("设为免费") {
                    store.setCustomPrice(.free, for: model)
                    dismiss()
                }
                if store.customPrices[model] != nil {
                    Button("恢复默认价格", role: .destructive) {
                        store.setCustomPrice(nil, for: model)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("模型价格")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let price = lookup.price {
                input = price.input
                output = price.output
                cached = price.cachedInput ?? price.input * 0.1
            }
        }
    }

    private func priceField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("$").foregroundStyle(.secondary)
            TextField("0", value: value, format: .number.precision(.fractionLength(0...4)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
        }
    }
}
