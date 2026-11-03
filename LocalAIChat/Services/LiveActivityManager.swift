import ActivityKit
import Foundation
import UIKit

/// 灵动岛 / 实时活动：在回复或浏览器任务进行时显示进度
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activities: [UUID: Activity<GenerationActivityAttributes>] = [:]
    private var lastStates: [UUID: GenerationActivityAttributes.ContentState] = [:]
    private var lastUpdate: [UUID: Date] = [:]
    /// 系统对实时活动的更新频率有限制，这里最多每 1.5 秒更新一次
    private let minimumInterval: TimeInterval = 1.5

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(conversationID: UUID, agent: Agent, title: String) {
        guard isAvailable else { return }
        endImmediately(conversationID)
        let attributes = GenerationActivityAttributes(
            agentName: agent.name,
            avatar: agent.avatar.isBlank ? "🤖" : agent.avatar,
            conversationTitle: title,
            conversationID: conversationID.uuidString,
            startedAt: Date()
        )
        let state = GenerationActivityAttributes.ContentState(phase: agent.browserEnabled ? .browsing : .thinking, detail: "", tokens: 0)
        do {
            activities[conversationID] = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            lastStates[conversationID] = state
            lastUpdate[conversationID] = Date()
        } catch {
            // 用户关闭了实时活动，或者数量达到系统上限
        }
    }

    /// 是否到了可以更新的时间（避免太频繁）
    func shouldUpdate(_ conversationID: UUID) -> Bool {
        guard activities[conversationID] != nil else { return false }
        guard let last = lastUpdate[conversationID] else { return true }
        return Date().timeIntervalSince(last) >= minimumInterval
    }

    func update(_ conversationID: UUID, phase: GenerationActivityAttributes.Phase? = nil, detail: String? = nil, tokens: Int? = nil, force: Bool = false) {
        guard let activity = activities[conversationID], force || shouldUpdate(conversationID) else { return }
        var state = lastStates[conversationID] ?? .init(phase: .thinking, detail: "", tokens: 0)
        if let phase { state.phase = phase }
        if let detail { state.detail = String(detail.suffix(160)) }
        if let tokens { state.tokens = tokens }
        guard state != lastStates[conversationID] else { return }
        lastStates[conversationID] = state
        lastUpdate[conversationID] = Date()
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// 结束。App 在前台时立即消失；在后台时保留一段时间，方便在锁屏上看到结果。
    func end(_ conversationID: UUID, success: Bool, preview: String, tokens: Int) {
        guard let activity = activities.removeValue(forKey: conversationID) else { return }
        lastStates[conversationID] = nil
        lastUpdate[conversationID] = nil
        let state = GenerationActivityAttributes.ContentState(
            phase: success ? .done : .failed,
            detail: String(preview.prefix(160)),
            tokens: tokens
        )
        let appActive = UIApplication.shared.applicationState == .active
        let policy: ActivityUIDismissalPolicy = appActive ? .immediate : .after(Date().addingTimeInterval(15 * 60))
        Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy) }
    }

    private func endImmediately(_ conversationID: UUID) {
        guard let activity = activities.removeValue(forKey: conversationID) else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
