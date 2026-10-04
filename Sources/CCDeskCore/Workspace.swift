import Foundation

public struct WorkspaceEntry: Codable, Equatable, Sendable {
    public var terminalID: UUID
    public var cwd: String
    /// 最近一次在该终端中看到的 Claude sessionId；为 nil 时恢复为普通 shell。
    public var sessionID: String?
    public var name: String
    public var kind: AgentKind?

    public init(terminalID: UUID, cwd: String, sessionID: String?, name: String, kind: AgentKind? = nil) {
        self.terminalID = terminalID
        self.cwd = cwd
        self.sessionID = sessionID
        self.name = name
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case terminalID, cwd, sessionID, name, kind
    }

    /// 自定义解码：`kind` 用 `try?` 容错，避免未来新增的 agent 种类（如 "codex"）让整份
    /// workspace 文件解码失败而被 WorkspaceStore.load 挪到一边。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminalID = try c.decode(UUID.self, forKey: .terminalID)
        cwd = try c.decode(String.self, forKey: .cwd)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        name = try c.decode(String.self, forKey: .name)
        kind = (try? c.decodeIfPresent(AgentKind.self, forKey: .kind)) ?? nil
    }
}

public struct WorkspaceFile: Codable, Equatable, Sendable {
    public var version: Int
    public var entries: [WorkspaceEntry]
    /// 主窗口详情区的分屏布局（设计 §20）；旧文件没有这一项。
    public var layout: PaneLayout?

    public init(version: Int = 1, entries: [WorkspaceEntry], layout: PaneLayout? = nil) {
        self.version = version
        self.entries = entries
        self.layout = layout
    }
}

public enum WorkspaceStore {
    public static let defaultURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".cc-desk/workspace.json")

    public static func load(from url: URL = defaultURL) -> WorkspaceFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let file = try? JSONDecoder().decode(WorkspaceFile.self, from: data) { return file }
        // 文件存在但解码失败：先挪到一边保留现场，避免随后的 save() 把它悄悄覆盖丢失。
        let seconds = Int(Date().timeIntervalSince1970)
        let brokenName = "\(url.deletingPathExtension().lastPathComponent).broken-\(seconds).json"
        let brokenURL = url.deletingLastPathComponent().appendingPathComponent(brokenName)
        try? FileManager.default.moveItem(at: url, to: brokenURL)
        return nil
    }

    public static func save(_ file: WorkspaceFile, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
    }
}
