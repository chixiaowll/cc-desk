import Foundation

public struct EmbeddedTerminalInfo: Equatable, Sendable {
    public let id: UUID
    public let cwd: String
    public let tty: String?
    public let title: String
    public let createdAt: Date
    /// 该终端里最近一次退出的 agent sessionId（agent 已退出、终端还留着 shell 时）。
    public let lastSessionID: String?
    /// 最近一次退出的 agent 种类。
    public let lastKind: AgentKind
    /// agent 退出的时间（若已知）。
    public let endedAt: Date?

    public init(id: UUID, cwd: String, tty: String?, title: String, createdAt: Date,
                lastSessionID: String? = nil, lastKind: AgentKind = .claude, endedAt: Date? = nil) {
        self.id = id
        self.cwd = cwd
        self.tty = tty
        self.title = title
        self.createdAt = createdAt
        self.lastSessionID = lastSessionID
        self.lastKind = lastKind
        self.endedAt = endedAt
    }
}

/// 一个正在运行的 Codex / pi 进程及其已合并的状态（会话、状态由 App 层从会话文件 / hook / 屏幕规则得出）。
public struct AgentProcessInfo: Equatable, Sendable {
    public let pid: Int32
    public let kind: AgentKind
    public let tty: String?
    public let cwd: String
    public let sessionID: String?
    public let status: AgentStatus
    public let statusChangedAt: Date

    public init(pid: Int32, kind: AgentKind, tty: String?, cwd: String, sessionID: String?,
                status: AgentStatus, statusChangedAt: Date) {
        self.pid = pid
        self.kind = kind
        self.tty = tty
        self.cwd = cwd
        self.sessionID = sessionID
        self.status = status
        self.statusChangedAt = statusChangedAt
    }
}

public enum SessionBuilder {
    /// 外部会话的宿主；内嵌终端由调用方先按 tty 匹配。
    static func externalHost(pid: Int32, tty: String?, processes: ProcessTable, entrypoint: String? = nil) -> SessionHost {
        if let tty, processes.hasAncestor(of: pid, where: { $0.command.contains("/Terminal.app/") }) {
            return .terminalApp(tty: tty)
        }
        if entrypoint == "claude-vscode"
            || processes.hasAncestor(of: pid, where: { $0.command.contains("/Visual Studio Code.app/") || $0.command.contains("/Code Helper") }) {
            return .vscode
        }
        return .other(tty: tty)
    }

    public static func build(registry: [RegistryEntry], processes: ProcessTable,
                             embedded: [EmbeddedTerminalInfo], missing: [WorkspaceEntry],
                             agents: [AgentProcessInfo] = []) -> [AgentSession] {
        var embeddedByTTY: [String: EmbeddedTerminalInfo] = [:]
        for info in embedded {
            if let tty = info.tty { embeddedByTTY[tty] = info }
        }

        var result: [AgentSession] = []
        var claimedTerminals: Set<UUID> = []

        // 同一 tty 上可能残留旧 session 的记录（进程仍在退出中），较新的优先。
        // pid 存活且其 ps comm 的最后一段确为 "claude" 才算有效；否则说明 pid 被复用或记录已过期。
        let live = registry
            .filter { entry in
                guard let proc = processes.byPID[entry.pid] else { return false }
                let lastComponent = proc.command.split(separator: "/").last.map(String.init) ?? proc.command
                return lastComponent == "claude"
            }
            .sorted {
                if $0.statusUpdatedAt != $1.statusUpdatedAt { return $0.statusUpdatedAt > $1.statusUpdatedAt }
                return $0.pid > $1.pid
            }

        for entry in live {
            let tty = processes.tty(of: entry.pid)
            let host: SessionHost
            let id: String
            if let tty, let info = embeddedByTTY[tty] {
                if claimedTerminals.contains(info.id) { continue }
                claimedTerminals.insert(info.id)
                host = .embedded(terminalID: info.id)
                id = "term:\(info.id.uuidString)"
            } else {
                host = externalHost(pid: entry.pid, tty: tty, processes: processes, entrypoint: entry.entrypoint)
                id = "claude-pid:\(entry.pid)"
            }
            result.append(AgentSession(
                id: id, kind: .claude, sessionID: entry.sessionID, pid: entry.pid, tty: tty,
                cwd: entry.cwd, name: entry.name ?? "", nameIsDerived: entry.nameIsDerived,
                host: host, status: entry.status, statusChangedAt: entry.statusUpdatedAt))
        }

        // Codex / pi：外部会话 id 为 "<kind>-pid:<pid>"。
        for agent in agents.sorted(by: { $0.pid < $1.pid }) {
            let host: SessionHost
            let id: String
            if let tty = agent.tty, let info = embeddedByTTY[tty] {
                if claimedTerminals.contains(info.id) { continue }
                claimedTerminals.insert(info.id)
                host = .embedded(terminalID: info.id)
                id = "term:\(info.id.uuidString)"
            } else {
                host = externalHost(pid: agent.pid, tty: agent.tty, processes: processes)
                id = "\(agent.kind.rawValue)-pid:\(agent.pid)"
            }
            result.append(AgentSession(
                id: id, kind: agent.kind, sessionID: agent.sessionID, pid: agent.pid, tty: agent.tty,
                cwd: agent.cwd, name: "", nameIsDerived: true,
                host: host, status: agent.status, statusChangedAt: agent.statusChangedAt))
        }

        for info in embedded where !claimedTerminals.contains(info.id) {
            if let sid = info.lastSessionID {
                result.append(AgentSession(
                    id: "term:\(info.id.uuidString)", kind: info.lastKind, sessionID: sid, pid: nil, tty: info.tty,
                    cwd: info.cwd, name: info.title, nameIsDerived: false,
                    host: .embedded(terminalID: info.id), status: .ended,
                    statusChangedAt: info.endedAt ?? info.createdAt))
                continue
            }
            result.append(AgentSession(
                id: "term:\(info.id.uuidString)", kind: .other, sessionID: nil, pid: nil, tty: info.tty,
                cwd: info.cwd, name: info.title, nameIsDerived: false,
                host: .embedded(terminalID: info.id), status: .unknown, statusChangedAt: info.createdAt))
        }

        for entry in missing {
            result.append(AgentSession(
                id: "missing:\(entry.terminalID.uuidString)",
                kind: entry.sessionID == nil ? .other : (entry.kind.flatMap { $0.isAgent ? $0 : nil } ?? .claude),
                sessionID: entry.sessionID,
                pid: nil, tty: nil, cwd: entry.cwd, name: entry.name, nameIsDerived: false,
                host: .missing(terminalID: entry.terminalID), status: .unknown,
                statusChangedAt: .distantPast))
        }
        return result
    }
}
