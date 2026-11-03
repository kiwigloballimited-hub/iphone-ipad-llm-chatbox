import AppIntents
import SwiftUI
import WidgetKit

// MARK: - 配置

enum QuickAskMode: String, AppEnum {
    case voice
    case newChat

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "点击后"
    static var caseDisplayRepresentations: [QuickAskMode: DisplayRepresentation] = [
        .voice: "语音提问",
        .newChat: "新对话",
    ]
}

/// 小组件设置。免费开发者账号下小组件读不到 App 的数据，所以助手按名称填写。
struct QuickAskConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "快速提问"
    static var description = IntentDescription("点一下小组件，就能和指定的助手开始对话或语音提问。")

    @Parameter(title: "助手名称", description: "与 App 中的助手名称一致；留空则使用第一个助手")
    var agentName: String?

    @Parameter(title: "图标", default: "🤖")
    var emoji: String

    @Parameter(title: "点击后", default: .voice)
    var mode: QuickAskMode
}

// MARK: - Timeline

struct QuickAskEntry: TimelineEntry {
    let date: Date
    let configuration: QuickAskConfigIntent
}

struct QuickAskProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuickAskEntry {
        QuickAskEntry(date: Date(), configuration: QuickAskConfigIntent())
    }

    func snapshot(for configuration: QuickAskConfigIntent, in context: Context) async -> QuickAskEntry {
        QuickAskEntry(date: Date(), configuration: configuration)
    }

    func timeline(for configuration: QuickAskConfigIntent, in context: Context) async -> Timeline<QuickAskEntry> {
        // 内容是静态的，不需要定时刷新
        Timeline(entries: [QuickAskEntry(date: Date(), configuration: configuration)], policy: .never)
    }
}

// MARK: - Widget

struct QuickAskWidget: Widget {
    let kind = "QuickAskWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: QuickAskConfigIntent.self, provider: QuickAskProvider()) { entry in
            QuickAskWidgetView(entry: entry)
        }
        .configurationDisplayName("快速提问")
        .description("一键打开助手，开始新对话或语音提问。长按可以设置助手和点击后的动作。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct QuickAskWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickAskEntry

    private var name: String {
        let value = entry.configuration.agentName?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? "本地AI" : value
    }

    private var emoji: String {
        let value = entry.configuration.emoji.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "🤖" : String(value.prefix(2))
    }

    private var voice: Bool { entry.configuration.mode == .voice }
    private var agentRef: String? { entry.configuration.agentName }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: voice ? "mic.fill" : "bubble.left.fill")
                    .font(.title3)
            }
            .widgetURL(DeepLink.newChat(agent: agentRef, voice: voice))
            .containerBackground(for: .widget) { Color.clear }

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label(name, systemImage: voice ? "mic.fill" : "bubble.left.fill")
                    .font(.headline)
                    .widgetAccentable()
                Text(voice ? "点按语音提问" : "点按开始新对话")
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(DeepLink.newChat(agent: agentRef, voice: voice))
            .containerBackground(for: .widget) { Color.clear }

        case .accessoryInline:
            Label("\(name) · \(voice ? "语音提问" : "新对话")", systemImage: voice ? "mic.fill" : "bubble.left.fill")
                .widgetURL(DeepLink.newChat(agent: agentRef, voice: voice))
                .containerBackground(for: .widget) { Color.clear }

        case .systemMedium:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(emoji).font(.system(size: 40))
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("本地AI")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(spacing: 10) {
                    Link(destination: DeepLink.newChat(agent: agentRef, voice: true)) {
                        actionLabel("语音提问", systemImage: "mic.fill")
                    }
                    Link(destination: DeepLink.newChat(agent: agentRef, voice: false)) {
                        actionLabel("新对话", systemImage: "square.and.pencil")
                    }
                }
            }
            .containerBackground(for: .widget) { background }

        default:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(emoji).font(.system(size: 36))
                    Spacer()
                    Image(systemName: voice ? "mic.circle.fill" : "plus.bubble.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(voice ? "点按语音提问" : "点按开始新对话")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .widgetURL(DeepLink.newChat(agent: agentRef, voice: voice))
            .containerBackground(for: .widget) { background }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [Color(red: 0.0, green: 0.62, blue: 0.58), Color(red: 0.02, green: 0.33, blue: 0.32)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 120, height: 40)
            .background(Capsule().fill(.white.opacity(0.22)))
    }
}
