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
    /// needsInput 时这次等批准的编号（`WaitingEpisodes`）：处理按钮 / 语音批准时核对仍是同一次等待，
    /// 同样的命令再次请求批准也算新的一次。由 App 在检测到事件后填上。
    public var episode: Int?

    public init(kind: Kind, sessionKey: String, title: String, body: String,
                reason: String? = nil, actionable: Bool = false, episode: Int? = nil) {
        self.kind = kind
        self.sessionKey = sessionKey
        self.title = title
        self.body = body
        self.reason = reason
        self.actionable = actionable
        self.episode = episode
    }
}

/// 每个会话当前这次等批准的编号：进入等批准、或等待原因变了，就换一个新编号（全局递增，不会重复）。
/// 同时记下这次等待开始的时刻（调用方的时钟，App 用 systemUptime），供语音批准判断用户是不是在请求出现之后才说的。
/// 只在一个线程上使用（App 在主线程，每次轮询后 `update`）。
public struct WaitingEpisodes: Equatable, Sendable {
    public struct Episode: Equatable, Sendable {
        public let id: Int
        public let reason: String?
        public let since: TimeInterval
    }

    private var counter: Int
    public private(set) var current: [String: Episode] = [:]

    /// base：编号起点。App 用启动时刻，上次运行留下的通知不会碰巧对上这次的编号。
    public init(base: Int = 0) {
        counter = base
    }

    /// 用本轮所有会话的状态更新；不在等批准 / 已消失的会话清掉编号。
    public mutating func update(statuses: [String: AgentStatus], now: TimeInterval) {
        var next: [String: Episode] = [:]
        for (key, status) in statuses {
            guard case .waiting(let reason) = status else { continue }
            if let existing = current[key], existing.reason == reason {
                next[key] = existing
            } else {
                counter += 1
                next[key] = Episode(id: counter, reason: reason, since: now)
            }
        }
        current = next
    }

    public func episode(_ key: String) -> Episode? { current[key] }

    /// 给 needsInput 事件填上编号。
    public func stamp(_ events: [StatusEvent]) -> [StatusEvent] {
        events.map { event in
            guard event.kind == .needsInput else { return event }
            var stamped = event
            stamped.episode = current[event.sessionKey]?.id
            return stamped
        }
    }
}

/// 一批状态变化事件分别交给谁：系统通知、推送到手机、标记「已完成·未读」（纯逻辑，App 负责执行）。
public enum EventRouting {
    public struct Routes: Equatable, Sendable {
        /// 发系统通知的事件。
        public let notify: [StatusEvent]
        /// 交给推送的事件（是否真的推送还要看推送设置与时机，见 `PushPolicy.shouldPush`）。
        public let push: [StatusEvent]
        /// 新的「已完成·未读」行。
        public let unread: Set<String>
    }

    /// - 系统通知 / 未读：App 可见且正看着的那个会话不发（用户就在看）。
    /// - 推送：别的会话照常交给推送；正看着的会话只在用户离开 Mac 时推送（App 仍在前台、选中这个会话，但人已走开）。
    ///   presence 只在需要时才取（App 层采集要调系统接口）。
    public static func route(events: [StatusEvent], selected: String?, appVisible: Bool,
                             presence: () -> PushPresence) -> Routes {
        var notify: [StatusEvent] = []
        var push: [StatusEvent] = []
        var unread = Set<String>()
        var away: Bool?
        for event in events {
            let watched = appVisible && event.sessionKey == selected
            if !watched {
                notify.append(event)
                push.append(event)
                if event.kind == .finished { unread.insert(event.sessionKey) }
                continue
            }
            if away == nil { away = PushPolicy.isAway(presence()) }
            if away == true { push.append(event) }
        }
        return Routes(notify: notify, push: push, unread: unread)
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
    /// expectedReason 为发通知时的等待原因。expectedEpisode 为发通知 / 播报时这次等批准的编号，
    /// currentEpisode 为现在的编号（`WaitingEpisodes`）：给了 expectedEpisode 时两者必须相同——
    /// 原因相同（包括都没有原因）但已是另一次等待（同样的命令又请求了一次）也不能替用户批准。
    public static func decide(expectedReason: String?, expectedEpisode: Int? = nil, host: SessionHost?,
                              status: AgentStatus?, currentEpisode: Int? = nil) -> Decision {
        guard let host, let status else { return .gone }
        guard host.isEmbedded else { return .notEmbedded }
        guard case .waiting(let current) = status else { return .notWaiting }
        guard current == expectedReason else { return .reasonChanged }
        if let expectedEpisode, expectedEpisode != currentEpisode { return .reasonChanged }
        return .apply
    }
}

/// Claude Code / Codex 权限对话框的应答按键（对话模式、助手工具、通知按钮共用）。
public enum PermissionPrompt {
    /// 对话框默认高亮第一项「Yes」，回车即批准；Esc 拒绝。
    public static func keys(approve: Bool) -> String {
        approve ? "\r" : "\u{1b}"
    }
}
