import Foundation

public enum CCDeskCore {
    public static let version = "0.1.0"
}

/// 会话的 agent 种类。原始值写入 workspace.json；未知值由 `WorkspaceEntry` 宽松解码为 nil。
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case pi
    /// 普通 shell（内嵌终端里没有运行任何 agent）。
    case other

    /// 界面上显示的 agent 名。
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .pi: return "pi"
        case .other: return L("agent.terminal")
        }
    }

    /// 是否是一个 agent（而非普通 shell）。
    public var isAgent: Bool { self != .other }

    /// 新建会话时可选的 agent，按显示顺序。
    public static let launchable: [AgentKind] = [.claude, .codex, .pi]
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
        case .waiting: return L("status.waiting")
        case .working: return L("status.working")
        case .idle: return L("status.idle")
        case .ended: return L("status.ended")
        case .unknown: return L("status.unknown")
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
