import Foundation

/// 启动时如何恢复 workspace 里的一个内嵌终端（设计 §4.9）。
public enum TerminalRestoreDecision: Equatable, Sendable {
    /// tmux 会话还在：直接附着，不发恢复命令（agent 仍在运行）。
    case attach
    /// 没有存活的会话：新建终端并执行 `command`（agent 的恢复 / 启动命令；nil 为普通 shell）。
    case create(command: String?)
    /// 目录已不存在、也没有存活的会话：显示为「目录缺失」。
    case missing
}

public struct TerminalRestoreItem: Equatable, Sendable {
    public let entry: WorkspaceEntry
    public let decision: TerminalRestoreDecision

    public init(entry: WorkspaceEntry, decision: TerminalRestoreDecision) {
        self.entry = entry
        self.decision = decision
    }
}

public struct TerminalRestorePlan: Equatable, Sendable {
    public let items: [TerminalRestoreItem]
    /// CC Desk 服务器里没有 workspace 记录的 `ccdesk-*` 会话名：启动时结束掉。
    public let orphanSessions: [String]

    public init(items: [TerminalRestoreItem], orphanSessions: [String]) {
        self.items = items
        self.orphanSessions = orphanSessions
    }
}

public enum TerminalRestorePlanner {
    /// 记录的 agent 种类：有 sessionId 时按其 agent 恢复（旧文件没有 kind 时为 Claude）；只有 kind 没有 sessionId
    /// （如 Codex 还没发过第一条消息）时重新启动该 agent；都没有时为 nil（普通 shell）。
    public static func kind(for entry: WorkspaceEntry) -> AgentKind? {
        entry.kind.flatMap { $0.isAgent ? $0 : nil } ?? (entry.sessionID != nil ? .claude : nil)
    }

    /// 没有存活会话时新建终端要执行的命令。
    public static func command(for entry: WorkspaceEntry) -> String? {
        let adapter = kind(for: entry).flatMap(AgentAdapters.adapter(for:))
        if let sid = entry.sessionID { return adapter?.resumeCommand(sessionID: sid) }
        return adapter?.launchCommand()
    }

    /// `liveSessions`：CC Desk tmux 服务器里现有的会话名（没有 tmux / 服务器未运行时为空）。
    /// 会话存活时即使目录已被删除也附着（进程还在跑）；否则按目录是否存在决定新建或标记缺失。
    public static func plan(entries: [WorkspaceEntry], liveSessions: [String],
                            directoryExists: (String) -> Bool) -> TerminalRestorePlan {
        let live = Set(liveSessions.compactMap(TmuxNaming.terminalID(fromSessionName:)))
        let items = entries.map { entry -> TerminalRestoreItem in
            if live.contains(entry.terminalID) { return TerminalRestoreItem(entry: entry, decision: .attach) }
            guard directoryExists(entry.cwd) else { return TerminalRestoreItem(entry: entry, decision: .missing) }
            return TerminalRestoreItem(entry: entry, decision: .create(command: command(for: entry)))
        }
        let known = Set(entries.map(\.terminalID))
        var seen: Set<String> = []
        let orphans = liveSessions.filter { name in
            guard name.hasPrefix(TmuxNaming.sessionPrefix), seen.insert(name).inserted else { return false }
            // `ccdesk-` 前缀但不是合法 UUID 的也是 CC Desk 服务器里的残留，一并清理。
            guard let id = TmuxNaming.terminalID(fromSessionName: name) else { return true }
            return !known.contains(id)
        }
        return TerminalRestorePlan(items: items, orphanSessions: orphans)
    }
}
