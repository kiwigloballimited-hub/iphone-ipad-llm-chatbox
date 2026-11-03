import SwiftUI

/// 三栏布局：助手列表 › 对话列表 › 聊天。iPad 上并排显示，iPhone 上自动变为逐级推入。
struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedAgentID: UUID?
    @State private var selectedConversationID: UUID?

    var body: some View {
        NavigationSplitView {
            AgentListView(selection: $selectedAgentID)
        } content: {
            if let agentID = selectedAgentID, store.agent(id: agentID) != nil {
                ConversationListView(agentID: agentID, selection: $selectedConversationID)
            } else {
                ContentUnavailableView("选择一个助手", systemImage: "person.2", description: Text("每个助手都有独立的人格设定和对话记录"))
            }
        } detail: {
            if let conversationID = selectedConversationID, store.conversation(id: conversationID) != nil {
                ChatView(conversationID: conversationID)
                    .id(conversationID)
            } else {
                ContentUnavailableView("开始对话", systemImage: "bubble.left.and.bubble.right", description: Text("选择或新建一个对话"))
            }
        }
        .onChange(of: selectedAgentID) { _, _ in
            if let target = store.navigationTarget, let conversation = store.conversation(id: target),
               conversation.agentID == selectedAgentID {
                return // 分支跳转导致的切换，保留目标对话
            }
            selectedConversationID = nil
        }
        .onChange(of: store.navigationTarget) { _, target in
            // 例如新建分支后，跳转到新对话
            guard let target, let conversation = store.conversation(id: target) else { return }
            if selectedAgentID != conversation.agentID {
                selectedAgentID = conversation.agentID
            }
            selectedConversationID = target
            DispatchQueue.main.async { store.navigationTarget = nil }
        }
    }
}

struct AgentAvatar: View {
    let avatar: String
    var size: CGFloat = 40

    var body: some View {
        Text(avatar.isBlank ? "🤖" : avatar)
            .font(.system(size: size * 0.55))
            .frame(width: size, height: size)
            .background(Circle().fill(Color(.secondarySystemBackground)))
    }
}
