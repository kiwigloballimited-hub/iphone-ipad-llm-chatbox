import SwiftUI

// MARK: - 记忆本

/// 某个助手的长期记忆列表：查看、添加、编辑、删除
struct MemoryListView: View {
    @Environment(AppStore.self) private var store
    let agentID: UUID

    @State private var newText = ""
    @State private var editing: MemoryItem?
    @State private var confirmClear = false

    var body: some View {
        let items = store.memories(for: agentID)

        List {
            Section {
                TextField("添加一条记忆，例如：用户的女儿在读五年级", text: $newText, axis: .vertical)
                    .lineLimit(1...4)
                Button("添加", systemImage: "plus.circle.fill") {
                    store.addMemory(newText, to: agentID)
                    newText = ""
                }
                .disabled(newText.isBlank)
            } footer: {
                Text("记忆本里的内容会在这个助手的每一次对话中自动带上，所以新开对话它也记得。")
            }

            Section {
                if items.isEmpty {
                    Text("还没有记忆")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    Button {
                        editing = item
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text)
                                .foregroundStyle(Color.primary)
                                .multilineTextAlignment(.leading)
                            Text("\(Self.sourceLabel(item.source)) · \(item.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("删除", systemImage: "trash") { store.deleteMemory(item.id) }
                            .tint(.red)
                    }
                }
            } header: {
                Text("已记住 \(items.count) 条")
            }

            if !items.isEmpty {
                Section {
                    Button("清空全部记忆", role: .destructive) { confirmClear = true }
                }
            }
        }
        .navigationTitle("记忆本")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { item in
            MemoryEditSheet(item: item)
        }
        .confirmationDialog("清空这个助手的全部记忆？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { store.clearMemories(for: agentID) }
        }
    }

    static func sourceLabel(_ source: MemoryItem.Source) -> String {
        switch source {
        case .manual: return String(localized: "手动添加")
        case .extracted: return String(localized: "从对话中记住")
        case .auto: return String(localized: "自动记住")
        }
    }
}

/// 作为弹出页使用的记忆本
struct MemoryBookSheet: View {
    @Environment(\.dismiss) private var dismiss
    let agentID: UUID

    var body: some View {
        NavigationStack {
            MemoryListView(agentID: agentID)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

private struct MemoryEditSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let item: MemoryItem
    @State private var text: String

    init(item: MemoryItem) {
        self.item = item
        _text = State(initialValue: item.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("记忆内容", text: $text, axis: .vertical)
                    .lineLimit(3...12)
                Section {
                    Button("删除这条记忆", role: .destructive) {
                        store.deleteMemory(item.id)
                        dismiss()
                    }
                }
            }
            .navigationTitle("编辑记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.updateMemory(item.id, text: text)
                        dismiss()
                    }
                    .disabled(text.isBlank)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 从对话中提取的候选记忆

struct MemoryCandidateBatch: Identifiable {
    let id = UUID()
    let texts: [String]
}

/// 让用户确认（可修改、可取消勾选）要记住的内容
struct MemoryCandidatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: ([String]) -> Void

    private struct Candidate: Identifiable {
        let id = UUID()
        var text: String
        var selected = true
    }

    @State private var candidates: [Candidate]

    init(batch: MemoryCandidateBatch, onSave: @escaping ([String]) -> Void) {
        self.onSave = onSave
        _candidates = State(initialValue: batch.texts.map { Candidate(text: $0) })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($candidates) { $candidate in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: candidate.selected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(candidate.selected ? Color.accentColor : Color.secondary)
                                .onTapGesture { candidate.selected.toggle() }
                            TextField("", text: $candidate.text, axis: .vertical)
                                .lineLimit(1...6)
                                .foregroundStyle(candidate.selected ? Color.primary : Color.secondary)
                        }
                    }
                } footer: {
                    Text("点击圆圈选择要记住的内容，也可以直接修改文字。记住的内容会出现在这个助手的记忆本里，之后的所有对话都会用到。")
                }
            }
            .navigationTitle("要记住这些吗？")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    let selected = candidates.filter { $0.selected && !$0.text.isBlank }
                    Button("记住 \(selected.count) 条") {
                        onSave(selected.map(\.text))
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

// MARK: - 早期对话摘要

struct ConversationSummarySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID

    var body: some View {
        let conversation = store.conversation(id: conversationID)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let summary = conversation?.summary, !summary.isBlank {
                        Text(summary)
                            .textSelection(.enabled)
                        if let until = conversation?.summaryCoversUntil {
                            Text("已覆盖到 \(until.formatted(date: .abbreviated, time: .shortened)) 之前的消息")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("还没有摘要。对话超过「记忆的历史消息」条数后，早期内容会自动压缩成摘要。")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("早期对话摘要")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                if conversation?.summary != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("清除", role: .destructive) {
                            store.clearSummary(conversationID)
                        }
                    }
                }
            }
        }
    }
}
