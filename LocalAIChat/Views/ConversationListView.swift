import SwiftUI

struct ConversationListView: View {
    @Environment(AppStore.self) private var store
    let agentID: UUID
    @Binding var selection: UUID?

    @State private var editingAgent: Agent?
    @State private var renamingConversation: Conversation?
    @State private var renameText = ""

    var body: some View {
        let agent = store.agent(id: agentID)
        let conversations = store.conversations(for: agentID)

        List(selection: $selection) {
            if let agent {
                Section {
                    HStack(spacing: 14) {
                        AgentAvatar(avatar: agent.avatar, size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agent.name).font(.title3.bold())
                            let model = store.effectiveModel(for: agent)
                            Text(model.isEmpty ? "未设置模型" : model)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("编辑") { editingAgent = agent }
                            .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("对话") {
                ForEach(conversations) { conversation in
                    NavigationLink(value: conversation.id) {
                        ConversationRow(conversation: conversation, isGenerating: store.isGenerating(conversation.id))
                    }
                    .contextMenu {
                        Button("重命名", systemImage: "pencil") {
                            renameText = conversation.title
                            renamingConversation = conversation
                        }
                        Button("删除", systemImage: "trash", role: .destructive) {
                            delete(conversation.id)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("删除", systemImage: "trash") { delete(conversation.id) }
                            .tint(.red)
                    }
                }

                Button {
                    selection = store.newConversation(for: agentID)
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                }
            }
        }
        .navigationTitle(agent?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    selection = store.newConversation(for: agentID)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("新对话")
            }
        }
        .sheet(item: $editingAgent) { agent in
            AgentEditorView(agent: agent, isNew: false)
        }
        .alert("重命名对话", isPresented: Binding(get: { renamingConversation != nil }, set: { if !$0 { renamingConversation = nil } })) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) { renamingConversation = nil }
            Button("确定") {
                if let conversation = renamingConversation {
                    store.renameConversation(conversation.id, to: renameText)
                }
                renamingConversation = nil
            }
        }
    }

    private func delete(_ id: UUID) {
        if selection == id { selection = nil }
        store.deleteConversation(id)
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let isGenerating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(conversation.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(conversation.preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}
