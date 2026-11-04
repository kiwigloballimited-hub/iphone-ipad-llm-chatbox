import SwiftUI

struct AgentListView: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: UUID?

    @State private var showSettings = false
    @State private var editingAgent: Agent?
    @State private var agentPendingDeletion: Agent?

    var body: some View {
        List(selection: $selection) {
            ForEach(store.agents) { agent in
                NavigationLink(value: agent.id) {
                    AgentRow(agent: agent, model: store.effectiveModel(for: agent))
                }
                .contextMenu {
                    Button("编辑", systemImage: "pencil") { editingAgent = agent }
                    Button("复制", systemImage: "plus.square.on.square") { store.duplicateAgent(agent) }
                    Button("删除", systemImage: "trash", role: .destructive) { agentPendingDeletion = agent }
                }
                .swipeActions(edge: .trailing) {
                    Button("删除", systemImage: "trash") { agentPendingDeletion = agent }
                        .tint(.red)
                    Button("编辑", systemImage: "pencil") { editingAgent = agent }
                        .tint(.orange)
                }
            }
            .onMove { store.moveAgents(from: $0, to: $1) }
        }
        .navigationTitle("助手")
        .overlay {
            if store.agents.isEmpty {
                ContentUnavailableView {
                    Label("还没有助手", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("点击右上角 + 创建一个助手")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("空白助手", systemImage: "person.crop.circle.badge.plus") {
                        editingAgent = Agent(serverID: store.servers.first?.id)
                    }
                    Section("从模板创建") {
                        ForEach(PersonaTemplates.all) { template in
                            Button("\(template.avatar) \(template.name)") {
                                editingAgent = template.makeAgent(serverID: store.servers.first?.id)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建助手")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $editingAgent) { agent in
            AgentEditorView(agent: agent, isNew: store.agent(id: agent.id) == nil)
        }
        .confirmationDialog(
            String(localized: "删除助手「\(agentPendingDeletion?.name ?? "")」？"),
            isPresented: Binding(get: { agentPendingDeletion != nil }, set: { if !$0 { agentPendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除助手及其所有对话", role: .destructive) {
                if let agent = agentPendingDeletion {
                    if selection == agent.id { selection = nil }
                    store.deleteAgent(agent.id)
                }
                agentPendingDeletion = nil
            }
        }
    }
}

private struct AgentRow: View {
    let agent: Agent
    let model: String

    var body: some View {
        HStack(spacing: 12) {
            AgentAvatar(avatar: agent.avatar, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let role = agent.persona.useCustomPrompt ? agent.persona.customPrompt : agent.persona.role
        let modelText = model.isEmpty ? String(localized: "未设置模型") : model
        return role.isBlank ? modelText : "\(modelText) · \(role.trimmed)"
    }
}
