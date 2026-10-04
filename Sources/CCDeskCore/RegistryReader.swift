import Foundation

/// `~/.claude/sessions/<pid>.json` 中的一条记录。格式无公开文档，解析必须宽松。
public struct RegistryEntry: Equatable, Sendable {
    public let pid: Int32
    public let sessionID: String
    public let cwd: String
    public let name: String?
    public let nameIsDerived: Bool
    public var status: AgentStatus
    public let statusUpdatedAt: Date
    public let entrypoint: String?
    /// 注册表里的原始 status 字符串（缺失时为 nil）。
    public let rawStatus: String?
    /// 这一轮已结束、在等用户，但仍有后台任务在跑（Claude Code 的 `"shell"`：「1 shell still running」）。
    /// 此时 status 为 `.idle`。
    public var backgroundWork: Bool

    public init(pid: Int32, sessionID: String, cwd: String, name: String?, nameIsDerived: Bool,
                status: AgentStatus, statusUpdatedAt: Date, entrypoint: String?,
                rawStatus: String? = nil, backgroundWork: Bool = false) {
        self.pid = pid
        self.sessionID = sessionID
        self.cwd = cwd
        self.name = name
        self.nameIsDerived = nameIsDerived
        self.status = status
        self.statusUpdatedAt = statusUpdatedAt
        self.entrypoint = entrypoint
        self.rawStatus = rawStatus
        self.backgroundWork = backgroundWork
    }

    /// 原始 status 是否是已知取值（未知 / 缺失时由 `RegistryStatusMemory` 兜底）。
    public var hasKnownStatus: Bool { RegistryReader.status(raw: rawStatus, waitingFor: nil) != nil }
}

public enum RegistryReader {
    public static let defaultDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/sessions", isDirectory: true)

    public static func parse(_ data: Data) -> RegistryEntry? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (obj["pid"] as? NSNumber)?.int32Value,
              let sessionID = obj["sessionId"] as? String, !sessionID.isEmpty,
              let cwd = obj["cwd"] as? String, !cwd.isEmpty
        else { return nil }
        if let kind = obj["kind"] as? String, kind != "interactive" { return nil }
        if (obj["spare"] as? Bool) == true { return nil }

        let raw = obj["status"] as? String
        let mapped = status(raw: raw, waitingFor: obj["waitingFor"] as? String)

        let millis = ["statusUpdatedAt", "updatedAt", "startedAt"]
            .lazy
            .compactMap { (obj[$0] as? NSNumber)?.doubleValue }
            .first
        let statusUpdatedAt = millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast

        return RegistryEntry(
            pid: pid,
            sessionID: sessionID,
            cwd: cwd,
            name: obj["name"] as? String,
            nameIsDerived: (obj["nameSource"] as? String) == "derived",
            status: mapped?.status ?? .unknown,
            statusUpdatedAt: statusUpdatedAt,
            entrypoint: obj["entrypoint"] as? String,
            rawStatus: raw,
            backgroundWork: mapped?.background ?? false
        )
    }

    /// 原始 status → 状态；未知 / 缺失返回 nil。
    /// `"shell"`：这一轮已结束、在等用户，但后台 shell 仍在跑——按空闲处理（不算等批准、working → shell 算完成一轮），
    /// 只额外带上「后台任务」标记。
    public static func status(raw: String?, waitingFor: String?) -> (status: AgentStatus, background: Bool)? {
        switch raw {
        case "busy": return (.working, false)
        case "idle": return (.idle, false)
        case "shell": return (.idle, true)
        case "waiting": return (.waiting(waitingFor), false)
        default: return nil
        }
    }

    public static func readAll(directory: URL = defaultDirectory) -> [RegistryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap(parse) }
    }
}

/// 注册表出现未知 status（Claude Code 新增的取值）或缺失 status 时的兜底：沿用该会话上一次已知的状态，
/// 而不是跳到「未知」。Claude 会话没有屏幕检测 / hook 兜底，而上一次的状态通常仍然成立（新取值多半是
/// 现有状态的细分，如 "shell" 之于空闲）。例外：上一次是「等批准」时降为「处理中」——不能让一个已离开的
/// 批准请求继续亮着（通知上的批准按钮会向终端发回车）。从没见过已知状态的会话仍为 `.unknown`。
/// 只在一个线程上使用（App 在主线程，每次轮询后 `resolve`）。
public struct RegistryStatusMemory: Sendable {
    private var last: [String: (status: AgentStatus, background: Bool)] = [:]

    public init() {}

    private static func key(_ entry: RegistryEntry) -> String { "\(entry.pid):\(entry.sessionID)" }

    /// 补全本轮记录的状态，并忘掉已消失的会话。
    public mutating func resolve(_ entries: [RegistryEntry]) -> [RegistryEntry] {
        var next: [String: (status: AgentStatus, background: Bool)] = [:]
        let resolved = entries.map { entry -> RegistryEntry in
            let key = Self.key(entry)
            var out = entry
            if entry.hasKnownStatus {
                next[key] = (entry.status, entry.backgroundWork)
            } else if let previous = last[key] {
                out.status = previous.status.isWaiting ? .working : previous.status
                out.backgroundWork = previous.status.isWaiting ? false : previous.background
                next[key] = (out.status, out.backgroundWork)
            }
            return out
        }
        last = next
        return resolved
    }
}
