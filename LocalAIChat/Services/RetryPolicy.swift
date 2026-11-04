import Foundation
import UIKit

/// 断线重传：判断哪些错误值得自动重试，以及如何从断点续写
enum RetryPolicy {
    /// 第 n 次重试前等待的秒数
    static func delaySeconds(forAttempt attempt: Int) -> Int {
        let schedule = [1, 3, 6, 10, 15]
        return schedule[min(max(attempt - 1, 0), schedule.count - 1)]
    }

    static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// 网络中断、超时、服务器暂时不可用等「过一会儿可能就好了」的错误
    static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .notConnectedToInternet, .timedOut,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .dataNotAllowed, .callIsActive, .internationalRoamingOff:
                return true
            default:
                return false
            }
        }
        if let llmError = error as? LLMError {
            switch llmError {
            case .http(let code, _):
                return [408, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524, 529].contains(code)
            case .server(let message):
                let text = message.lowercased()
                return ["overloaded", "timeout", "timed out", "temporarily", "unavailable", "rate limit", "connection reset"]
                    .contains { text.contains($0) }
            default:
                return false
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            // ENETDOWN, ENETUNREACH, ECONNABORTED, ECONNRESET, ENOTCONN, ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH
            return [50, 51, 53, 54, 57, 60, 61, 64, 65].contains(nsError.code)
        }
        return false
    }

    /// 已经生成了一部分时：把已生成的内容作为助手消息，再请模型从中断处接着写
    static func continuation(base: [RequestMessage], partial: String) -> [RequestMessage] {
        let tail = String(partial.suffix(120))
        return base + [
            RequestMessage(role: .assistant, text: partial),
            RequestMessage(
                role: .user,
                text: String(localized: "（系统提示：网络中断，你上一条回复只输出到「…\(tail)」为止。请从中断的地方直接接着写下去：不要重复已经写过的内容，不要重新开头，也不要提到中断。）")
            ),
        ]
    }
}

/// 生成过程中切到后台时，向系统申请额外的运行时间，尽量不断线
@MainActor
final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    static func begin(_ name: String) -> BackgroundActivity {
        let activity = BackgroundActivity()
        activity.identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak activity] in
            // 系统在主线程调用，必须在这里同步结束，否则 App 会被终止
            MainActor.assumeIsolated { activity?.end() }
        }
        return activity
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
