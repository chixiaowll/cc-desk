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
    /// workspace 里的项，后面接着被收养的会话（决定都是 `.attach`）。
    public let items: [TerminalRestoreItem]
    /// CC Desk 服务器里存活、但 workspace 没有记录的会话（如 workspace 文件缺失 / 损坏、或另一个实例写掉了记录）：
    /// 那里面多半是用户还在跑的 agent，作为内嵌终端收养（附着），从不结束。
    public let adopted: [UUID]
    /// `ccdesk-` 前缀但不是合法终端 id 的会话名：不认识，原样不动。
    public let unknownSessions: [String]

    public init(items: [TerminalRestoreItem], adopted: [UUID] = [], unknownSessions: [String] = []) {
        self.items = items
        self.adopted = adopted
        self.unknownSessions = unknownSessions
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
    /// 没有记录的存活会话被收养：`cwdOf` 给出窗格当前目录（取不到时用 `fallbackCwd`），名字取目录名，
    /// 不记 agent 种类与 sessionId（由之后的轮询从进程表认出来）。
    public static func plan(entries: [WorkspaceEntry], liveSessions: [String],
                            directoryExists: (String) -> Bool,
                            cwdOf: (String) -> String? = { _ in nil },
                            fallbackCwd: String = NSHomeDirectory()) -> TerminalRestorePlan {
        let live = Set(liveSessions.compactMap(TmuxNaming.terminalID(fromSessionName:)))
        var items = entries.map { entry -> TerminalRestoreItem in
            if live.contains(entry.terminalID) { return TerminalRestoreItem(entry: entry, decision: .attach) }
            guard directoryExists(entry.cwd) else { return TerminalRestoreItem(entry: entry, decision: .missing) }
            return TerminalRestoreItem(entry: entry, decision: .create(command: command(for: entry)))
        }
        var known = Set(entries.map(\.terminalID))
        var adopted: [UUID] = []
        var unknown: [String] = []
        var seen: Set<String> = []
        for name in liveSessions where name.hasPrefix(TmuxNaming.sessionPrefix) && seen.insert(name).inserted {
            guard let id = TmuxNaming.terminalID(fromSessionName: name) else {
                unknown.append(name)
                continue
            }
            guard known.insert(id).inserted else { continue }
            var cwd = cwdOf(name).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackCwd
            if !directoryExists(cwd) { cwd = fallbackCwd }
            let title = URL(fileURLWithPath: cwd).lastPathComponent
            let entry = WorkspaceEntry(terminalID: id, cwd: cwd, sessionID: nil, name: title.isEmpty ? cwd : title)
            items.append(TerminalRestoreItem(entry: entry, decision: .attach))
            adopted.append(id)
        }
        return TerminalRestorePlan(items: items, adopted: adopted, unknownSessions: unknown)
    }
}

/// `has-session` 的结果：区分「会话不在」与「服务器不在」「查询超时」，后两种不能当作会话已结束。
public enum TmuxSessionState: Equatable, Sendable {
    case alive
    /// 服务器在，会话不在（窗格 shell 已退出 / 会话被结束）。
    case missing
    /// 服务器没在运行（socket 不存在 / 连不上）。
    case noServer
    /// 超时或其他错误：不知道。
    case unknown

    /// exitStatus 为 nil 表示命令没跑完（超时 / 起不来）。
    public static func classify(exitStatus: Int32?, stderr: String) -> TmuxSessionState {
        guard let exitStatus else { return .unknown }
        if exitStatus == 0 { return .alive }
        if TmuxListing.isNoServer(stderr) { return .noServer }
        let text = stderr.lowercased()
        if text.contains("can't find session") || text.contains("session not found") { return .missing }
        return .unknown
    }
}

/// 内嵌终端里的 `tmux attach` 客户端退出后怎么办（设计 §4.9）。
public struct TmuxReattachPolicy: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// 会话还在（被外部 detach、客户端被杀）：重新附着。
        case reattach
        /// 会话可能还在，但短时间内反复断开：不再自动附着，保留终端（workspace 记录不丢）。
        case keepDetached
        /// 会话正常结束（用户 exit 了 shell / 会话被结束）：移除终端。
        case remove
        /// tmux 服务器崩溃 / 被结束：会话连同里面的进程都没了。保留终端的会话信息，显示为可恢复的「已结束」。
        case serverLost
    }

    public static let maxAttempts = 3
    /// 附着后稳定这么久，之前的失败次数清零。
    public static let stableAfter: TimeInterval = 30

    public private(set) var attempts = 0
    public private(set) var lastAttachAt: Date?

    public init() {}

    /// 记下一次（重新）附着。
    public mutating func noteAttached(at now: Date) {
        lastAttachAt = now
    }

    /// clientExitedCleanly：客户端退出码为 0（`[exited]` / `[detached]`）；服务器关闭 / 丢失时 tmux 客户端以 1 退出。
    /// 用它区分「最后一个会话正常结束、服务器随之退出（exit-empty）」与「服务器被结束 / 崩溃」。
    public mutating func onClientExit(state: TmuxSessionState, clientExitedCleanly: Bool, now: Date) -> Action {
        switch state {
        case .missing:
            return .remove
        case .noServer:
            return clientExitedCleanly ? .remove : .serverLost
        case .alive, .unknown:
            if let last = lastAttachAt, now.timeIntervalSince(last) >= Self.stableAfter { attempts = 0 }
            guard attempts < Self.maxAttempts else { return .keepDetached }
            attempts += 1
            lastAttachAt = now
            return .reattach
        }
    }
}
