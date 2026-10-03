import Foundation

/// hook / 扩展写入的状态文件 `~/.cc-desk/state/<tty>.json`（设计 §4.4）：
/// `{"agent","session_id","tty","pid","cwd","status":"working|waiting|idle","message"?,"ts":<毫秒>}`。
public struct HookState: Equatable, Sendable {
    public let agent: AgentKind
    public let sessionID: String?
    public let tty: String
    public let pid: Int32?
    public let cwd: String?
    public let status: AgentStatus
    public let updatedAt: Date

    public init(agent: AgentKind, sessionID: String?, tty: String, pid: Int32?, cwd: String?, status: AgentStatus, updatedAt: Date) {
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
              let tty = obj["tty"] as? String, !tty.isEmpty,
              let ts = (obj["ts"] as? NSNumber)?.doubleValue
        else { return nil }
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
        let pid = (obj["pid"] as? NSNumber)?.int32Value ?? (obj["pid"] as? String).flatMap(Int32.init)
        return HookState(agent: agent,
                         sessionID: (obj["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                         tty: tty, pid: pid,
                         cwd: (obj["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                         status: status, updatedAt: Date(timeIntervalSince1970: seconds))
    }

    /// tty -> 状态；同一 tty 只会有一个文件（文件名即 tty），文件内 tty 与文件名不一致时以文件内为准。
    public static func readAll(directory: URL = defaultDirectory) -> [String: HookState] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [String: HookState] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let state = parse(data) else { continue }
            if let existing = result[state.tty], existing.updatedAt > state.updatedAt { continue }
            result[state.tty] = state
        }
        return result
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
        guard hook.agent == kind, let tty, hook.tty == tty else { return false }
        if hook.pid == pid { return true }
        guard let start = processStart else { return false }
        return hook.updatedAt >= start.addingTimeInterval(-startSlack)
    }

    /// 返回合并后的状态；两者都没有时为 nil（调用方显示为未知）。
    /// - 屏幕上检测到等批准、且晚于 hook 的最近一次上报：显示等批准（Codex 的批准对话框不一定有 hook 事件）。
    /// - hook 超过 10 分钟未更新、屏幕在那之后有更新：用屏幕。
    /// - 其余情况 hook 优先。
    public static func merge(hook: StatusObservation?, screen: StatusObservation?, now: Date) -> StatusObservation? {
        guard let hook else { return screen }
        guard let screen else { return hook }
        if screen.status.isWaiting, !hook.status.isWaiting, screen.at >= hook.at { return screen }
        if now.timeIntervalSince(hook.at) > hookStaleAfter, screen.at > hook.at { return screen }
        return hook
    }
}
