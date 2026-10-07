import Foundation

/// 一个运行中的 Codex / pi 进程在某次轮询时的已知信息（后台队列产出，主线程再合并屏幕状态）。
public struct AgentProcessSnapshot: Equatable, Sendable {
    public let pid: Int32
    public let kind: AgentKind
    public let tty: String?
    public let cwd: String
    public let startedAt: Date?
    public let sessionID: String?
    /// 会话文件路径（已配对时）。
    public let sessionPath: String?
    public let hook: HookState?
    /// 会话文件最后写入的时间（agent 最后一次活动）；空闲状态从这时算起。
    public let lastActivity: Date?

    public init(pid: Int32, kind: AgentKind, tty: String?, cwd: String, startedAt: Date?,
                sessionID: String?, sessionPath: String?, hook: HookState?, lastActivity: Date? = nil) {
        self.pid = pid
        self.kind = kind
        self.tty = tty
        self.cwd = cwd
        self.startedAt = startedAt
        self.sessionID = sessionID
        self.sessionPath = sessionPath
        self.hook = hook
        self.lastActivity = lastActivity
    }
}

public enum AgentResolver {
    /// 进程的 cwd 与启动时间（由 App 层用 libproc 取得）。
    public typealias Details = (_ pid: Int32) -> (cwd: String?, startedAt: Date?)

    /// 识别进程表里的 Codex / pi，配对会话文件，并找到各自适用的 hook 状态。
    /// 会话 id 的来源（按优先级）：同 tty 的 hook 上报（pi 在会话文件写出之前就会上报）→ 命令行参数 → 会话文件配对。
    /// `fallbackSessions`：tty -> (种类, sessionId)，App 已知某个内嵌终端里应当在运行的会话（恢复 / 接管时发出的命令）；
    /// 只在其他来源都给不出会话时使用（例如 pi 恢复后还没写入会话文件）。
    public static func resolve(processes: ProcessTable, details: Details, hooks: HookStates,
                               index: AgentSessionIndex, fallbackSessions: [String: (kind: AgentKind, sessionID: String)] = [:],
                               now: Date = Date()) -> [AgentProcessSnapshot] {
        struct Pending {
            let proc: ProcInfo
            let kind: AgentKind
            let cwd: String?
            let start: Date?
            let ttyHook: HookState?
            let hint: String?
        }
        var pending: [Pending] = []
        for (proc, kind) in AgentProcessMatcher.agentProcesses(in: processes) {
            let d = details(proc.pid)
            let ttyHook = proc.tty.flatMap { tty in
                hooks.byTTY[tty].flatMap {
                    StatusMerger.hookApplies($0, kind: kind, pid: proc.pid, tty: tty, processStart: d.startedAt) ? $0 : nil
                }
            }
            let hint = ttyHook?.sessionID ?? AgentProcessMatcher.sessionHint(kind: kind, argv: proc.argv)
            pending.append(Pending(proc: proc, kind: kind, cwd: d.cwd, start: d.startedAt, ttyHook: ttyHook, hint: hint))
        }
        let matched = index.match(processes: pending.map {
            AgentProcessCandidate(pid: $0.proc.pid, kind: $0.kind, cwd: $0.cwd, startedAt: $0.start, sessionHint: $0.hint)
        }, now: now)
        return pending.map { p in
            var file = matched[p.proc.pid]
            var sessionID = file?.sessionID ?? p.ttyHook?.sessionID ?? p.hint
            var path = file?.path
            var lastActivity = file?.modifiedAt
            if sessionID == nil, let tty = p.proc.tty, let fallback = fallbackSessions[tty], fallback.kind == p.kind {
                sessionID = fallback.sessionID
                path = index.locate(kind: p.kind, sessionID: fallback.sessionID)
                file = nil
                lastActivity = path.flatMap {
                    (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
                }
            }
            let hook = p.ttyHook ?? hooks.state(kind: p.kind, pid: p.proc.pid, tty: p.proc.tty,
                                                sessionID: sessionID, processStart: p.start)
            return AgentProcessSnapshot(pid: p.proc.pid, kind: p.kind, tty: p.proc.tty,
                                        cwd: p.cwd ?? file?.cwd ?? hook?.cwd ?? NSHomeDirectory(),
                                        startedAt: p.start, sessionID: sessionID, sessionPath: path, hook: hook,
                                        lastActivity: lastActivity)
        }
    }

    /// 合并 hook 与屏幕状态；都没有时为未知（时间取进程启动时间）。
    /// 空闲时从会话文件最后写入的时间算起（lastActivity 更早时）：屏幕规则只在 App 启动后才开始观察，
    /// 不然重启 CC Desk 后一直空闲的会话会显示「1 分钟」，像是刚重新连上。
    public static func status(hook: HookState?, screen: StatusObservation?, startedAt: Date?, now: Date,
                              lastActivity: Date? = nil) -> StatusObservation {
        let hookObs = hook.map { StatusObservation(status: $0.status, at: $0.updatedAt) }
        var merged = StatusMerger.merge(hook: hookObs, screen: screen, now: now)
            ?? StatusObservation(status: .unknown, at: startedAt ?? .distantPast)
        if merged.status == .idle, let last = lastActivity, last < merged.at {
            merged = StatusObservation(status: .idle, at: last)
        }
        return merged
    }
}
