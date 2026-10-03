import Foundation

public struct StatusEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case needsInput
        case finished
    }

    public let kind: Kind
    /// AgentSession.id
    public let sessionKey: String
    public let title: String
    public let body: String

    public init(kind: Kind, sessionKey: String, title: String, body: String) {
        self.kind = kind
        self.sessionKey = sessionKey
        self.title = title
        self.body = body
    }
}

public enum TransitionDetector {
    /// previous 为 nil 表示首次加载，不产生事件；新出现的 session 也不产生事件。
    public static func events(previous: [String: AgentStatus]?, rows: [SidebarRow]) -> [StatusEvent] {
        guard let previous else { return [] }
        var out: [StatusEvent] = []
        for row in rows {
            guard let before = previous[row.id] else { continue }
            let now = row.session.status
            if case .waiting(let reason) = now, !before.isWaiting {
                out.append(StatusEvent(kind: .needsInput, sessionKey: row.id,
                                       title: L("notify.needsApproval.title", row.notificationName),
                                       body: reason ?? L("status.waitingForInput")))
            } else if now == .idle, before == .working {
                out.append(StatusEvent(kind: .finished, sessionKey: row.id,
                                       title: L("notify.finished.title", row.notificationName),
                                       body: L("notify.finished.body")))
            }
        }
        return out
    }
}
