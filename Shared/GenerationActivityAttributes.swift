import ActivityKit
import Foundation

/// 灵动岛 / 实时活动：显示正在进行的回复或浏览器任务（主 App 和小组件扩展共用）
struct GenerationActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case thinking   // 等待模型 / 思考中
        case writing    // 正在输出
        case browsing   // 浏览器助手正在操作网页
        case retrying   // 断线重连
        case done
        case failed
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// 当前步骤或回复预览
        var detail: String
        /// 已生成的 token（估算）
        var tokens: Int
    }

    var agentName: String
    var avatar: String
    var conversationTitle: String
    var conversationID: String
    var startedAt: Date
}

extension GenerationActivityAttributes.Phase {
    var label: String {
        switch self {
        case .thinking: return "思考中"
        case .writing: return "正在回复"
        case .browsing: return "正在浏览网页"
        case .retrying: return "重新连接中"
        case .done: return "已完成"
        case .failed: return "未完成"
        }
    }

    var symbol: String {
        switch self {
        case .thinking: return "brain"
        case .writing: return "text.bubble"
        case .browsing: return "globe"
        case .retrying: return "wifi.exclamationmark"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    var isFinal: Bool { self == .done || self == .failed }
}
