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
    /// needsInput 时的原始等待原因（未截断），用于处理通知按钮时核对请求是否已变化。
    public let reason: String?
    /// 是否可在通知上直接批准 / 拒绝：只有 CC Desk 内嵌终端里的等批准（外部终端无法输入）。
    public let actionable: Bool

    public init(kind: Kind, sessionKey: String, title: String, body: String,
                reason: String? = nil, actionable: Bool = false) {
        self.kind = kind
        self.sessionKey = sessionKey
        self.title = title
        self.body = body
        self.reason = reason
        self.actionable = actionable
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
                                       body: reason.map { ApprovalNotification.body($0) } ?? L("status.waitingForInput"),
                                       reason: reason, actionable: row.session.host.isEmbedded))
            } else if now == .idle, before == .working {
                out.append(StatusEvent(kind: .finished, sessionKey: row.id,
                                       title: L("notify.finished.title", row.notificationName),
                                       body: L("notify.finished.body")))
            }
        }
        return out
    }
}

/// 等批准通知上的「批准 / 拒绝」按钮：文案截断与执行前的状态复核（纯逻辑，App 层负责发键与提示）。
public enum ApprovalNotification {
    /// 通知正文最多显示的字符数（系统横幅大约显示两三行，过长的命令截断并加省略号）。
    public static let bodyLimit = 160

    /// 通知正文：等待原因压成一行（换行 / 连续空白变单个空格），超过 `limit` 截断加「…」。
    public static func body(_ reason: String, limit: Int = bodyLimit) -> String {
        let oneLine = reason.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard oneLine.count > limit, limit > 1 else { return oneLine }
        return String(oneLine.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    public enum Decision: Equatable, Sendable {
        /// 可以执行：会话仍在、是内嵌终端、仍在等批准且请求未变。
        case apply
        /// 会话已不在侧栏上（终端关闭 / 进程退出）。
        case gone
        /// 外部终端里的会话，CC Desk 无法输入。
        case notEmbedded
        /// 已不在等批准（已在别处处理过、或已结束）：此时回车会发出输入框内容、Esc 会打断 agent。
        case notWaiting
        /// 仍在等批准，但请求的内容已变（例如上一个已处理、又来了新的一个）：不能替用户批准没看过的请求。
        case reasonChanged
    }

    /// 处理按钮时复核：host / status 为点击时刻该会话的当前值（会话不存在时为 nil），
    /// expectedReason 为发通知时的等待原因。
    public static func decide(expectedReason: String?, host: SessionHost?, status: AgentStatus?) -> Decision {
        guard let host, let status else { return .gone }
        guard host.isEmbedded else { return .notEmbedded }
        guard case .waiting(let current) = status else { return .notWaiting }
        return current == expectedReason ? .apply : .reasonChanged
    }
}

/// Claude Code / Codex 权限对话框的应答按键（对话模式、助手工具、通知按钮共用）。
public enum PermissionPrompt {
    /// 对话框默认高亮第一项「Yes」，回车即批准；Esc 拒绝。
    public static func keys(approve: Bool) -> String {
        approve ? "\r" : "\u{1b}"
    }
}
