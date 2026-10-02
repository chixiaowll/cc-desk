import Foundation

public struct EmbeddedTerminalInfo: Equatable, Sendable {
    public let id: UUID
    public let cwd: String
    public let tty: String?
    public let title: String
    public let createdAt: Date

    public init(id: UUID, cwd: String, tty: String?, title: String, createdAt: Date) {
        self.id = id
        self.cwd = cwd
        self.tty = tty
        self.title = title
        self.createdAt = createdAt
    }
}

public enum SessionBuilder {
    public static func build(registry: [RegistryEntry], processes: ProcessTable,
                             embedded: [EmbeddedTerminalInfo], missing: [WorkspaceEntry]) -> [AgentSession] {
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
            } else if let tty, processes.hasAncestor(of: entry.pid, where: { $0.command.contains("/Terminal.app/") }) {
                host = .terminalApp(tty: tty)
                id = "claude-pid:\(entry.pid)"
            } else if entry.entrypoint == "claude-vscode"
                || processes.hasAncestor(of: entry.pid, where: { $0.command.contains("/Visual Studio Code.app/") || $0.command.contains("/Code Helper") }) {
                host = .vscode
                id = "claude-pid:\(entry.pid)"
            } else {
                host = .other(tty: tty)
                id = "claude-pid:\(entry.pid)"
            }
            result.append(AgentSession(
                id: id, kind: .claude, sessionID: entry.sessionID, pid: entry.pid, tty: tty,
                cwd: entry.cwd, name: entry.name ?? "", nameIsDerived: entry.nameIsDerived,
                host: host, status: entry.status, statusChangedAt: entry.statusUpdatedAt))
        }

        for info in embedded where !claimedTerminals.contains(info.id) {
            result.append(AgentSession(
                id: "term:\(info.id.uuidString)", kind: .other, sessionID: nil, pid: nil, tty: info.tty,
                cwd: info.cwd, name: info.title, nameIsDerived: false,
                host: .embedded(terminalID: info.id), status: .unknown, statusChangedAt: info.createdAt))
        }

        for entry in missing {
            result.append(AgentSession(
                id: "missing:\(entry.terminalID.uuidString)", kind: entry.sessionID == nil ? .other : .claude,
                sessionID: entry.sessionID,
                pid: nil, tty: nil, cwd: entry.cwd, name: entry.name, nameIsDerived: false,
                host: .missing(terminalID: entry.terminalID), status: .unknown,
                statusChangedAt: .distantPast))
        }
        return result
    }
}
