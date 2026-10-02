import Foundation

public enum CCDeskCore {
    public static let version = "0.1.0"
}

public enum AgentKind: String, Codable, Sendable {
    case claude
    case other
}

public enum AgentStatus: Equatable, Sendable {
    case working
    case waiting(String?)
    case idle
    /// 内嵌终端里的 claude 已退出，只剩普通 shell（可原地恢复）。
    case ended
    case unknown

    /// 排序用：数值越小越靠前。
    public var rank: Int {
        switch self {
        case .waiting: return 0
        case .working: return 1
        case .idle: return 2
        case .ended: return 3
        case .unknown: return 4
        }
    }

    public var label: String {
        switch self {
        case .waiting: return "等批准"
        case .working: return "处理中"
        case .idle: return "空闲"
        case .ended: return "已结束"
        case .unknown: return "未知"
        }
    }

    public var isActive: Bool {
        switch self {
        case .working, .waiting: return true
        case .idle, .ended, .unknown: return false
        }
    }

    public var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }
}

public enum SessionHost: Equatable, Sendable {
    case embedded(terminalID: UUID)
    case terminalApp(tty: String)
    case vscode
    case other(tty: String?)
    /// 恢复时原目录已不存在的占位。
    case missing(terminalID: UUID)

    public var isEmbedded: Bool {
        if case .embedded = self { return true }
        return false
    }

    public var terminalID: UUID? {
        switch self {
        case .embedded(let id), .missing(let id): return id
        default: return nil
        }
    }
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    /// 内嵌："term:<uuid>"；缺失占位："missing:<uuid>"；外部："claude-pid:<pid>"（按 pid 而非 sessionId 保证稳定唯一，
    /// 因为同一 sessionId 可能在多个终端中被恢复，且同一进程内 sessionId 可能切换）。
    public var id: String
    public var kind: AgentKind
    public var sessionID: String?
    public var pid: Int32?
    public var tty: String?
    public var cwd: String
    public var name: String
    public var nameIsDerived: Bool
    public var host: SessionHost
    public var status: AgentStatus
    public var statusChangedAt: Date

    public init(id: String, kind: AgentKind, sessionID: String?, pid: Int32?, tty: String?,
                cwd: String, name: String, nameIsDerived: Bool, host: SessionHost,
                status: AgentStatus, statusChangedAt: Date) {
        self.id = id
        self.kind = kind
        self.sessionID = sessionID
        self.pid = pid
        self.tty = tty
        self.cwd = cwd
        self.name = name
        self.nameIsDerived = nameIsDerived
        self.host = host
        self.status = status
        self.statusChangedAt = statusChangedAt
    }
}
