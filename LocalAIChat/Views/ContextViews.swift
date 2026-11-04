import SwiftUI

/// 分支对话顶部的说明，可以回到原对话
struct ForkBanner: View {
    @Environment(AppStore.self) private var store
    let conversation: Conversation

    var body: some View {
        let parentExists = conversation.parentID.flatMap { store.conversation(id: $0) } != nil
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("分支对话")
                    .font(.caption.weight(.semibold))
                Text("来自「\(conversation.parentTitle ?? String(localized: "原对话"))」" + (parentExists ? "" : String(localized: "（原对话已删除）")))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if parentExists, let parentID = conversation.parentID {
                Button("查看原对话") {
                    store.navigate(to: parentID)
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
    }
}

/// 消息之间的分隔线（上下文起点、分支起点）
struct ContextDivider: View {
    let title: String
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            line
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.caption2)
            }
            line
        }
        .padding(.vertical, 4)
    }

    private var line: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(height: 1)
    }
}

/// 当前对话中置顶的消息
struct PinnedMessagesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID

    var body: some View {
        let pinned = store.pinnedMessages(in: conversationID)
        let agentName = store.conversation(id: conversationID).flatMap { store.agent(id: $0.agentID) }?.name ?? String(localized: "助手")

        NavigationStack {
            List {
                if pinned.isEmpty {
                    ContentUnavailableView {
                        Label("没有置顶的消息", systemImage: "pin.slash")
                    } description: {
                        Text("长按任意消息，选择「置顶到上下文」。置顶的消息会一直发送给模型，不会因为对话太长被丢掉。")
                    }
                } else {
                    Section {
                        ForEach(pinned) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.role == .user ? String(localized: "你") : agentName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(ThinkParser.split(message.content).answer)
                                    .font(.callout)
                                    .lineLimit(6)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("取消置顶", systemImage: "pin.slash") {
                                    store.togglePin(message.id, in: conversationID)
                                }
                                .tint(.orange)
                            }
                        }
                    } footer: {
                        Text("置顶的消息超出「记忆的历史消息」范围后，会以「置顶的重要内容」的形式继续发送给模型。左滑可以取消置顶。")
                    }
                }
            }
            .navigationTitle("置顶的消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
