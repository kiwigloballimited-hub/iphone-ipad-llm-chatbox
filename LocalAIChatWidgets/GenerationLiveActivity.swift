import ActivityKit
import SwiftUI
import WidgetKit

/// 灵动岛与锁屏实时活动
struct GenerationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GenerationActivityAttributes.self) { context in
            LockScreenActivityView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.65))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(DeepLink.conversation(context.attributes.conversationID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.avatar)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusTrailing(context: context)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.agentName)
                            .font(.headline)
                            .lineLimit(1)
                        Label(context.state.phase.label, systemImage: context.state.phase.symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.detail.isEmpty ? context.attributes.conversationTitle : context.state.detail)
                        .font(.caption)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                }
            } compactLeading: {
                Text(context.attributes.avatar)
            } compactTrailing: {
                StatusTrailing(context: context)
            } minimal: {
                if context.state.phase.isFinal {
                    Image(systemName: context.state.phase.symbol)
                        .foregroundStyle(context.state.phase == .done ? .green : .orange)
                } else {
                    Text(context.attributes.avatar)
                }
            }
            .widgetURL(DeepLink.conversation(context.attributes.conversationID))
        }
    }
}

/// 右侧：进行中显示用时，结束后显示状态图标
private struct StatusTrailing: View {
    let context: ActivityViewContext<GenerationActivityAttributes>

    var body: some View {
        if context.state.phase.isFinal {
            Image(systemName: context.state.phase.symbol)
                .foregroundStyle(context.state.phase == .done ? .green : .orange)
        } else {
            Text(context.attributes.startedAt, style: .timer)
                .monospacedDigit()
                .font(.caption)
                .frame(maxWidth: 44)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct LockScreenActivityView: View {
    let context: ActivityViewContext<GenerationActivityAttributes>

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(context.attributes.avatar)
                .font(.system(size: 34))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(context.attributes.agentName)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    if context.state.phase.isFinal {
                        Label(context.state.phase.label, systemImage: context.state.phase.symbol)
                            .font(.caption)
                            .foregroundStyle(context.state.phase == .done ? .green : .orange)
                    } else {
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: 60, alignment: .trailing)
                    }
                }
                if !context.state.phase.isFinal {
                    Label(context.state.phase.label + (context.state.tokens > 0 ? " · 约 \(context.state.tokens) tokens" : ""), systemImage: context.state.phase.symbol)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(context.state.detail.isEmpty ? context.attributes.conversationTitle : context.state.detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
            }
        }
        .padding()
    }
}
