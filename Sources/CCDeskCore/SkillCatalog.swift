import Foundation

// MARK: - 技能库（设计 §21）：本机各 agent 的技能 / 命令 / 子 agent 的只读目录

/// 条目种类。
public enum SkillKind: String, Sendable, CaseIterable {
    /// `<dir>/SKILL.md` 形式的技能（pi 目录下根部的 .md 也算）。
    case skill
    /// Claude Code 斜杠命令（`commands/*.md`）。
    case command
    /// Claude Code 子 agent（`agents/*.md`）。
    case agent
    /// CC Desk 的专业 agent（`~/.cc-desk/agents/*.md`）。
    case ccdeskAgent

    var order: Int {
        switch self {
        case .skill: return 0
        case .command: return 1
        case .agent: return 2
        case .ccdeskAgent: return 3
        }
    }
}

/// 条目来自哪里。
public enum SkillSource: Hashable, Sendable {
    /// `~/.claude/skills`、`~/.claude/commands`、`~/.claude/agents`。
    case claudeUser
    /// claude.ai 同步到本机的技能（`~/.claude/skills/synced/<bucket>/`）。
    case claudeSynced
    /// 已安装的 Claude Code 插件（enabled 取自 `~/.claude/settings.json` 的 enabledPlugins）。
    case claudePlugin(plugin: String, marketplace: String, version: String?, enabled: Bool)
    /// 项目里的 `<root>/.claude/skills`。
    case claudeProject(root: String)
    /// `~/.agents/skills`（Codex 与 pi 都读）。
    case agentsShared
    /// 项目里的 `<root>/.agents/skills`（Codex 与 pi 都读）。
    case agentsProject(root: String)
    /// `~/.codex/skills`（含 `.system` 内置技能）。
    case codex
    /// `~/.pi/agent/skills`。
    case pi
    /// `~/.cc-desk/agents`。
    case ccdesk

    /// 会读到这个来源的 agent。
    public var agents: [AgentKind] {
        switch self {
        case .claudeUser, .claudeSynced, .claudePlugin, .claudeProject, .ccdesk: return [.claude]
        case .agentsShared, .agentsProject: return [.codex, .pi]
        case .codex: return [.codex]
        case .pi: return [.pi]
        }
    }

    /// 插件已停用。
    public var isDisabled: Bool {
        if case .claudePlugin(_, _, _, let enabled) = self { return !enabled }
        return false
    }

    /// 项目来源的根目录。
    public var projectRoot: String? {
        switch self {
        case .claudeProject(let root), .agentsProject(let root): return root
        default: return nil
        }
    }

    /// 分组用的稳定标识（列表的分区）。
    public var groupID: String {
        switch self {
        case .claudeUser: return "claude-user"
        case .claudeSynced: return "claude-synced"
        case .claudePlugin(let plugin, let marketplace, _, _): return "plugin:\(plugin)@\(marketplace)"
        case .claudeProject(let root): return "claude-project:\(root)"
        case .agentsShared: return "agents-shared"
        case .agentsProject(let root): return "agents-project:\(root)"
        case .codex: return "codex"
        case .pi: return "pi"
        case .ccdesk: return "ccdesk"
        }
    }

    /// 给助手看的简短来源名。
    public var label: String {
        switch self {
        case .claudeUser: return "claude-user"
        case .claudeSynced: return "claude-synced"
        case .claudePlugin(let plugin, _, _, _): return "plugin:\(plugin)"
        case .claudeProject(let root): return "project:\((root as NSString).lastPathComponent)"
        case .agentsShared: return "agents-shared"
        case .agentsProject(let root): return "agents-project:\((root as NSString).lastPathComponent)"
        case .codex: return "codex"
        case .pi: return "pi"
        case .ccdesk: return "ccdesk-agent"
        }
    }

    /// 排序：分区的先后。
    var order: Int {
        switch self {
        case .claudeUser: return 0
        case .claudeSynced: return 1
        case .claudePlugin: return 2
        case .claudeProject: return 3
        case .agentsShared: return 4
        case .agentsProject: return 5
        case .codex: return 6
        case .pi: return 7
        case .ccdesk: return 8
        }
    }

    /// 同一类来源内的次序（插件名 / 项目路径）。
    var sortKey: String {
        switch self {
        case .claudePlugin(let plugin, let marketplace, _, _): return "\(plugin)@\(marketplace)".lowercased()
        case .claudeProject(let root), .agentsProject(let root): return root
        default: return ""
        }
    }
}

/// 技能库里的一项。
public struct SkillEntry: Identifiable, Equatable, Sendable {
    /// 稳定标识：主来源 + 文件（解析符号链接后的）路径。
    public let id: String
    public let name: String
    /// 显示名（CC Desk 专业 agent 的 title）；没有时为 nil。
    public let title: String?
    public let description: String
    public let kind: SkillKind
    /// 主来源（= sources[0]）。同一个文件从多处链接进来时（如 `~/.claude/skills/x -> ~/.agents/skills/x`）合并成一项。
    public let sources: [SkillSource]
    /// 能用到它的 agent（各来源的并集）。
    public let agents: [AgentKind]
    /// SKILL.md / 命令 / agent 文件的路径（按发现时的路径，不解析符号链接）。
    public let filePath: String
    /// 技能所在目录；单文件条目（命令、子 agent、专业 agent）为 nil。
    public let folderPath: String?

    public init(name: String, title: String? = nil, description: String, kind: SkillKind, sources: [SkillSource],
                filePath: String, folderPath: String?, resolvedPath: String? = nil) {
        let primary = sources.first ?? .claudeUser
        self.id = "\(primary.groupID)|\(resolvedPath ?? filePath)"
        self.name = name
        self.title = title
        self.description = description
        self.kind = kind
        self.sources = sources.isEmpty ? [.claudeUser] : sources
        var agents: [AgentKind] = []
        for source in self.sources { for agent in source.agents where !agents.contains(agent) { agents.append(agent) } }
        self.agents = AgentKind.allCases.filter(agents.contains)
        self.filePath = filePath
        self.folderPath = folderPath
    }

    public var source: SkillSource { sources[0] }

    /// 显示名：有 title 时用 title。
    public var displayName: String { title ?? name }

    /// 只来自已停用的插件。
    public var isDisabled: Bool { sources.allSatisfy(\.isDisabled) }

    /// 对某个会话是否生效：Claude 读个人 / 云同步 / 已启用插件 / 这个项目的 `.claude/skills`；Codex 读 `~/.codex/skills`
    /// 与 `.agents/skills`（个人和这个项目）；pi 读 `~/.pi/agent/skills` 与 `.agents/skills`。CC Desk 专业 agent 不算技能。
    /// projectRoot 为会话所在的项目根目录；cwd 在某个项目来源的根目录之下也算这个项目。
    public func applies(to kind: AgentKind, cwd: String, projectRoot: String?) -> Bool {
        sources.contains { source in
            guard source.agents.contains(kind) else { return false }
            switch source {
            case .ccdesk: return false
            case .claudePlugin(_, _, _, let enabled): return enabled
            case .claudeProject(let root), .agentsProject(let root):
                return Self.path(cwd, isInside: root) || projectRoot.map { Self.path($0, isInside: root) } == true
            default: return true
            }
        }
    }

    static func path(_ path: String, isInside root: String) -> Bool {
        let root = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
        return path == root || path.hasPrefix(root + "/")
    }

    /// 搜索：query 里每个词都出现在名字、显示名或描述里（不区分大小写）；空 query 全部匹配。
    public func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = [name, title ?? "", description].joined(separator: "\n")
        return words.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }

    /// 给助手看的一项（list_skills）：路径相对 home 写成 `~/…`。
    public func json(home: String) -> JSONValue {
        var item: [String: JSONValue] = [
            "name": .string(name), "description": .string(AssistantContext.clip(description, 160)),
            "kind": .string(kind.rawValue), "source": .string(source.label), "enabled": .bool(!isDisabled),
            "agents": .array(agents.map { .string($0.rawValue) }),
            "path": .string(SkillCatalog.tildePath(filePath, home: home)),
        ]
        if let title { item["title"] = .string(title) }
        return .object(item)
    }
}

public enum SkillCatalog {
    /// 排序：来源分区 → 来源内次序 → 种类 → 名字（不区分大小写）→ 路径。
    public static func sorted(_ entries: [SkillEntry]) -> [SkillEntry] {
        entries.sorted { a, b in
            if a.source.order != b.source.order { return a.source.order < b.source.order }
            if a.source.sortKey != b.source.sortKey { return a.source.sortKey < b.source.sortKey }
            if a.kind.order != b.kind.order { return a.kind.order < b.kind.order }
            let an = a.name.lowercased(), bn = b.name.lowercased()
            if an != bn { return an < bn }
            return a.filePath < b.filePath
        }
    }

    /// 按 agent 与关键字过滤。
    public static func filter(_ entries: [SkillEntry], query: String?, agent: AgentKind?) -> [SkillEntry] {
        entries.filter { entry in
            (agent == nil || agent.map(entry.agents.contains) == true) && entry.matches(query ?? "")
        }
    }

    /// 对某个会话生效的条目。
    public static func effective(_ entries: [SkillEntry], for kind: AgentKind, cwd: String,
                                 projectRoot: String?) -> [SkillEntry] {
        entries.filter { $0.applies(to: kind, cwd: cwd, projectRoot: projectRoot) }
    }

    /// `/Users/x/a` → `~/a`。
    public static func tildePath(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
