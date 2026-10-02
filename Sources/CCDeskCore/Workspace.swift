import Foundation

public struct WorkspaceEntry: Codable, Equatable, Sendable {
    public var terminalID: UUID
    public var cwd: String
    /// 最近一次在该终端中看到的 Claude sessionId；为 nil 时恢复为普通 shell。
    public var sessionID: String?
    public var name: String

    public init(terminalID: UUID, cwd: String, sessionID: String?, name: String) {
        self.terminalID = terminalID
        self.cwd = cwd
        self.sessionID = sessionID
        self.name = name
    }
}

public struct WorkspaceFile: Codable, Equatable, Sendable {
    public var version: Int
    public var entries: [WorkspaceEntry]

    public init(version: Int = 1, entries: [WorkspaceEntry]) {
        self.version = version
        self.entries = entries
    }
}

public enum WorkspaceStore {
    public static let defaultURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".cc-desk/workspace.json")

    public static func load(from url: URL = defaultURL) -> WorkspaceFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WorkspaceFile.self, from: data)
    }

    public static func save(_ file: WorkspaceFile, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
    }
}
