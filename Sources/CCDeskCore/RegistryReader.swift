import Foundation

/// `~/.claude/sessions/<pid>.json` 中的一条记录。格式无公开文档，解析必须宽松。
public struct RegistryEntry: Equatable, Sendable {
    public let pid: Int32
    public let sessionID: String
    public let cwd: String
    public let name: String?
    public let nameIsDerived: Bool
    public let status: AgentStatus
    public let statusUpdatedAt: Date
    public let entrypoint: String?

    public init(pid: Int32, sessionID: String, cwd: String, name: String?, nameIsDerived: Bool,
                status: AgentStatus, statusUpdatedAt: Date, entrypoint: String?) {
        self.pid = pid
        self.sessionID = sessionID
        self.cwd = cwd
        self.name = name
        self.nameIsDerived = nameIsDerived
        self.status = status
        self.statusUpdatedAt = statusUpdatedAt
        self.entrypoint = entrypoint
    }
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

        let status: AgentStatus
        switch obj["status"] as? String {
        case "busy": status = .working
        case "idle": status = .idle
        case "waiting": status = .waiting(obj["waitingFor"] as? String)
        default: status = .unknown
        }

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
            status: status,
            statusUpdatedAt: statusUpdatedAt,
            entrypoint: obj["entrypoint"] as? String
        )
    }

    public static func readAll(directory: URL = defaultDirectory) -> [RegistryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap(parse) }
    }
}
