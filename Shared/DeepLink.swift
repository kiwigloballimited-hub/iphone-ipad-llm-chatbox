import Foundation

/// App 内跳转链接（小组件、实时活动使用）
/// - localaichat://new?agent=写作伙伴&voice=1   新对话（可选：助手名称或 ID、直接语音提问）
/// - localaichat://conversation?id=UUID        打开某个对话
enum DeepLink {
    static let scheme = "localaichat"

    static func newChat(agent: String? = nil, voice: Bool = false) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "new"
        var items: [URLQueryItem] = []
        if let agent, !agent.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "agent", value: agent))
        }
        if voice { items.append(URLQueryItem(name: "voice", value: "1")) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url ?? URL(string: "\(scheme)://new")!
    }

    static func conversation(_ id: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "conversation"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url ?? URL(string: "\(scheme)://new")!
    }
}
