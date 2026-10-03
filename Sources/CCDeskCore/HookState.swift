import Foundation

/// hook / 扩展写入的状态文件 `~/.cc-desk/state/<tty>.json`（设计 §4.4）：
/// `{"agent","session_id","tty","pid","cwd","status":"working|waiting|idle","message"?,"ts":<毫秒>}`。
/// Codex 0.160 在共享的 app-server 守护进程里执行 hook，父进程链上没有 tty：此时 tty 为空，
/// 文件名为 `codex-<session_id>.json`，由 App 按会话 id 对应到进程。
public struct HookState: Equatable, Sendable {
    public let agent: AgentKind
    public let sessionID: String?
    /// 写入者所在终端；hook 拿不到 tty 时为 nil（此时必有 sessionID）。
    public let tty: String?
    public let pid: Int32?
    public let cwd: String?
    public let status: AgentStatus
    public let updatedAt: Date

    public init(agent: AgentKind, sessionID: String?, tty: String?, pid: Int32?, cwd: String?, status: AgentStatus, updatedAt: Date) {
        self.agent = agent
        self.sessionID = sessionID
        self.tty = tty
        self.pid = pid
        self.cwd = cwd
        self.status = status
        self.updatedAt = updatedAt
    }
}

public enum HookStateReader {
    public static let defaultDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".cc-desk/state", isDirectory: true)

    public static func parse(_ data: Data) -> HookState? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let agent = (obj["agent"] as? String).flatMap(AgentKind.init(rawValue:)), agent.isAgent,
              let ts = (obj["ts"] as? NSNumber)?.doubleValue
        else { return nil }
        let tty = (obj["tty"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let sessionID = (obj["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard tty != nil || sessionID != nil else { return nil }
        let message = (obj["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let status: AgentStatus
        switch obj["status"] as? String {
        case "working": status = .working
        case "waiting": status = .waiting(message)
        case "idle": status = .idle
        default: return nil
        }
        // 兼容秒与毫秒。
        let seconds = ts > 1e11 ? ts / 1000 : ts
        let rawPID = (obj["pid"] as? NSNumber)?.int32Value ?? (obj["pid"] as? String).flatMap(Int32.init)
        let pid = rawPID.flatMap { $0 > 0 ? $0 : nil }
        return HookState(agent: agent, sessionID: sessionID, tty: tty, pid: pid,
                         cwd: (obj["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                         status: status, updatedAt: Date(timeIntervalSince1970: seconds))
    }

    /// 读取目录下全部状态文件（跳过临时文件与无法解析的文件）。
    public static func readAll(directory: URL = defaultDirectory) -> HookStates {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var states: [HookState] = []
        for url in files where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix(".") {
            guard let data = try? Data(contentsOf: url), let state = parse(data) else { continue }
            states.append(state)
        }
        return HookStates(states)
    }
}

/// 按 tty 与按 (agent, 会话 id) 索引的 hook 状态；同一键有多份时取最新。
public struct HookStates: Sendable {
    public private(set) var byTTY: [String: HookState] = [:]
    public private(set) var bySession: [String: HookState] = [:]

    public init(_ states: [HookState] = []) {
        for s in states {
            if let tty = s.tty, byTTY[tty].map({ $0.updatedAt <= s.updatedAt }) ?? true { byTTY[tty] = s }
            if let sid = s.sessionID {
                let key = "\(s.agent.rawValue):\(sid)"
                if bySession[key].map({ $0.updatedAt <= s.updatedAt }) ?? true { bySession[key] = s }
            }
        }
    }

    /// 某个 agent 进程适用的 hook 状态：先按 tty（同一终端里旧进程留下的不算），再按已知的会话 id。
    public func state(kind: AgentKind, pid: Int32, tty: String?, sessionID: String?, processStart: Date?) -> HookState? {
        if let tty, let s = byTTY[tty], StatusMerger.hookApplies(s, kind: kind, pid: pid, tty: tty, processStart: processStart) {
            return s
        }
        if let sid = sessionID, let s = bySession["\(kind.rawValue):\(sid)"], s.agent == kind {
            if s.pid == pid { return s }
            // 同一会话可能先后被不同进程恢复：只认本进程启动之后写的。
            if let start = processStart, s.updatedAt >= start.addingTimeInterval(-StatusMerger.startSlack) { return s }
        }
        return nil
    }
}

/// 某个来源在某一时刻观察到的状态。
public struct StatusObservation: Equatable, Sendable {
    public let status: AgentStatus
    /// 该来源最近一次给出（或改变）这个状态的时间。
    public let at: Date

    public init(status: AgentStatus, at: Date) {
        self.status = status
        self.at = at
    }
}

/// 多来源状态合并（设计 §4.2）：hook > 屏幕规则 > 进程。
public enum StatusMerger {
    /// hook 超过这么久没更新、而屏幕有更新时，改用屏幕。
    public static let hookStaleAfter: TimeInterval = 600
    /// 进程启动时间与 hook 时间戳比较的容差（hook 由子进程写入，时间可能略早于 ps 看到的启动时间取整）。
    static let startSlack: TimeInterval = 2

    /// hook 状态是否属于这个进程：同 agent、同 tty，且（pid 一致，或写于进程启动之后）。
    /// 同一终端里先后运行的不同进程会共用 `<tty>.json`，旧进程留下的状态不能用于新进程。
    public static func hookApplies(_ hook: HookState, kind: AgentKind, pid: Int32, tty: String?, processStart: Date?) -> Bool {
        guard hook.agent == kind, let tty, let hookTTY = hook.tty, hookTTY == tty else { return false }
        if hook.pid == pid { return true }
        guard let start = processStart else { return false }
        return hook.updatedAt >= start.addingTimeInterval(-startSlack)
    }

    /// 返回合并后的状态；两者都没有时为 nil（调用方显示为未知）。
    /// - 屏幕上检测到等批准、且晚于 hook 的最近一次上报：显示等批准（Codex 的批准对话框不一定有 hook 事件）。
    /// - hook 停在等批准、屏幕在那之后显示不再等批准：用屏幕（批准后到下一个 hook 事件之前）。
    /// - hook 超过 10 分钟未更新、屏幕在那之后有更新：用屏幕。
    /// - 其余情况 hook 优先。
    public static func merge(hook: StatusObservation?, screen: StatusObservation?, now: Date) -> StatusObservation? {
        guard let hook else { return screen }
        guard let screen else { return hook }
        if screen.status.isWaiting, !hook.status.isWaiting, screen.at >= hook.at { return screen }
        if hook.status.isWaiting, !screen.status.isWaiting, screen.at > hook.at { return screen }
        if now.timeIntervalSince(hook.at) > hookStaleAfter, screen.at > hook.at { return screen }
        return hook
    }
}
