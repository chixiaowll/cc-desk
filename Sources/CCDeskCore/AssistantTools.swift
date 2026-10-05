import Foundation

/// 助手工具（设计 §13）的定义：MCP `tools/list` 的内容，同时也是控制接口的方法名。
/// 新增工具：在 `all` 里加一项，再在 App 的工具执行器里实现同名方法。
public struct AssistantToolSpec: Equatable, Sendable {
    public struct Parameter: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case string, integer, boolean
        }

        public let name: String
        public let kind: Kind
        public let description: String
        public let required: Bool
        public let options: [String]

        public init(_ name: String, _ kind: Kind, _ description: String, required: Bool = false, options: [String] = []) {
            self.name = name
            self.kind = kind
            self.description = description
            self.required = required
            self.options = options
        }
    }

    public let name: String
    public let description: String
    public let parameters: [Parameter]
    /// 是否只读（MCP annotations.readOnlyHint）。
    public let readOnly: Bool

    public init(name: String, description: String, parameters: [Parameter] = [], readOnly: Bool = false) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.readOnly = readOnly
    }

    /// JSON Schema（MCP `inputSchema`）。
    public var inputSchema: JSONValue {
        var properties: [String: JSONValue] = [:]
        for p in parameters {
            var prop: [String: JSONValue] = ["type": .string(p.kind.rawValue), "description": .string(p.description)]
            if !p.options.isEmpty { prop["enum"] = .array(p.options.map(JSONValue.string)) }
            properties[p.name] = .object(prop)
        }
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        let required = parameters.filter(\.required).map { JSONValue.string($0.name) }
        if !required.isEmpty { schema["required"] = .array(required) }
        return .object(schema)
    }

    /// MCP `tools/list` 里的一项。
    public var mcpDescriptor: JSONValue {
        ["name": .string(name), "description": .string(description), "inputSchema": inputSchema,
         "annotations": ["readOnlyHint": .bool(readOnly)]]
    }
}

public enum AssistantTools {
    static let sessionRef = "Session: short id from list_sessions (e.g. s3), or words from its title/dir; " +
        "omit or \"current\" for the selected session."

    public static let all: [AssistantToolSpec] = [
        AssistantToolSpec(
            name: "list_sessions",
            description: "List the sidebar sessions: id, title, dir, agent, status (waiting_for_approval includes " +
                "what it wants), selected, embedded (false = runs in an external terminal: read-only, can be taken over), " +
                "model (name + full id of the model it currently uses, when known).",
            readOnly: true),
        AssistantToolSpec(
            name: "read_screen",
            description: "Read the visible terminal screen (bottom lines, plain text) of a session inside CC Desk.",
            parameters: [.init("session", .string, sessionRef),
                         .init("lines", .integer, "Number of bottom lines, default 40, max 200.")],
            readOnly: true),
        AssistantToolSpec(
            name: "read_transcript",
            description: "Read the tail of a session's transcript (USER / ASSISTANT / EDIT / RUN / OUTPUT / ERROR lines). " +
                "Use it to answer what a session did, changed or concluded.",
            parameters: [.init("session", .string, sessionRef),
                         .init("turns", .integer, "Number of recent user turns to include, default 1, max 5.")],
            readOnly: true),
        AssistantToolSpec(
            name: "list_history",
            description: "List past sessions that can be resumed (id like h2, title, dir, agent), newest first.",
            parameters: [.init("query", .string, "Optional words to filter by title or dir.")],
            readOnly: true),
        AssistantToolSpec(
            name: "list_projects",
            description: "List project directories where a new session can be started.",
            readOnly: true),
        AssistantToolSpec(
            name: "git_status",
            description: "Git branch, changed files and the last 5 commits of a project.",
            parameters: [.init("project", .string, "Project name or path; omit for the selected session's project.")],
            readOnly: true),
        AssistantToolSpec(
            name: "switch_to",
            description: "Show a session in CC Desk. An external session asks the user to confirm taking it over.",
            parameters: [.init("session", .string, sessionRef, required: true)]),
        AssistantToolSpec(
            name: "type_text",
            description: "Type text into the input box of a session inside CC Desk (any session, not only the selected one). " +
                "submit=true also presses Enter to send it.",
            parameters: [.init("session", .string, sessionRef),
                         .init("text", .string, "The exact text to type.", required: true),
                         .init("submit", .boolean, "Press Enter afterwards, default false.")]),
        AssistantToolSpec(
            name: "clear_input",
            description: "Delete the text CC Desk typed into a session's input box that has not been sent yet.",
            parameters: [.init("session", .string, sessionRef)]),
        AssistantToolSpec(
            name: "press_key",
            description: "Press a key in a session inside CC Desk. ctrl-c asks the user to confirm.",
            parameters: [.init("session", .string, sessionRef),
                         .init("key", .string, "Key to press.", required: true,
                               options: ["enter", "escape", "ctrl-c", "up", "down", "tab"])]),
        AssistantToolSpec(
            name: "respond_approval",
            description: "Approve or deny the permission prompt of a session that is waiting_for_approval.",
            parameters: [.init("session", .string, sessionRef),
                         .init("approve", .boolean, "true = approve, false = deny.", required: true)]),
        AssistantToolSpec(
            name: "new_session",
            description: "Start a new agent session in a project; an optional prompt is sent as its first message.",
            parameters: [.init("project", .string, "Project name or path (see list_projects).", required: true),
                         .init("agent", .string, "Agent, default claude.", options: ["claude", "codex", "pi"]),
                         .init("prompt", .string, "Optional first message for the new agent.")]),
        AssistantToolSpec(
            name: "resume_session",
            description: "Reopen a past session from list_history.",
            parameters: [.init("history_id", .string, "History id (e.g. h2) or words from its title.", required: true)]),
        AssistantToolSpec(
            name: "close_session",
            description: "Close a session inside CC Desk. Asks the user to confirm.",
            parameters: [.init("session", .string, sessionRef, required: true)]),
        AssistantToolSpec(
            name: "consult",
            description: "Ask a stronger model (the senior assistant) a question that needs real reasoning or reading " +
                "code: why something fails, how code works, design choices, reviewing a diff. Runs in the background, " +
                "read-only (it can read files and run read-only git, never change anything) and returns at once with a " +
                "job id; the answer arrives later as a [CONSULT_RESULT] message. Max 2 at a time, up to 5 minutes each.",
            parameters: [.init("question", .string, "The full question, self-contained (the advisor sees nothing else).",
                               required: true),
                         .init("level", .string, "Model. Default sonnet. Use opus ONLY when the user explicitly asks " +
                               "for Opus (\"用 Opus\", \"最强的模型\").", options: ["sonnet", "opus"]),
                         .init("project", .string, "Project name or path to look at; omit for the selected session's project."),
                         .init("profile", .string, "Optional read-only specialist from list_agents (e.g. reviewer).")]),
        AssistantToolSpec(
            name: "delegate",
            description: "Hand a task that changes code or runs commands to a new visible agent session in a project " +
                "(it appears in the sidebar and the task is sent as its first message). CC Desk tells you later when it " +
                "needs approval or finishes. Use a profile from list_agents for specialist work (reviewer, tester).",
            parameters: [.init("project", .string, "Project name or path (see list_projects).", required: true),
                         .init("task", .string, "The task, in the user's words.", required: true),
                         .init("agent", .string, "Agent, default claude.", options: ["claude", "codex", "pi"]),
                         .init("profile", .string, "Optional specialist profile name from list_agents (claude only).")]),
        AssistantToolSpec(
            name: "list_agents",
            description: "List the specialist agent profiles (name, title, description, model, readOnly). readOnly " +
                "profiles can be used with consult; any profile can be used with delegate.",
            readOnly: true),
        AssistantToolSpec(
            name: "list_skills",
            description: "List the skills installed on this Mac for Claude Code, Codex and pi (personal, claude.ai " +
                "synced, plugins, project and shared skills, plugin commands / subagents) and the CC Desk specialist " +
                "agents: name, description, kind, source, enabled (false = plugin disabled), agents, path.",
            parameters: [.init("query", .string, "Optional words to match in the name or description."),
                         .init("agent", .string, "Only what this agent can use.", options: ["claude", "codex", "pi"])],
            readOnly: true),
        AssistantToolSpec(
            name: "list_consults",
            description: "List recent consult jobs with their state (running / done / failed / cancelled / timedOut) " +
                "and, when done, the short conclusion.",
            readOnly: true),
        AssistantToolSpec(
            name: "cancel_consult",
            description: "Cancel a running consult job.",
            parameters: [.init("job", .string, "Job id from consult / list_consults (e.g. c2); omit for the latest running.")]),
        AssistantToolSpec(
            name: "open_file",
            description: "Show a file a session's agent wrote, edited, generated with a command or mentioned in its " +
                "replies: the most recent document-like one (md, html, pdf, image, video, csv, office document…), " +
                "optionally matching words from its name or path. Opens it in the system Quick Look panel (default) " +
                "or in its default app.",
            parameters: [.init("session", .string, sessionRef),
                         .init("query", .string, "Optional words from the file name or path (e.g. report, README)."),
                         .init("app", .boolean, "true = open in the default app instead of Quick Look, default false.")]),
        AssistantToolSpec(
            name: "take_over",
            description: "Move an external terminal session into CC Desk (it is restarted with resume). Asks the user to confirm.",
            parameters: [.init("session", .string, sessionRef, required: true)]),
    ]

    public static func spec(named name: String) -> AssistantToolSpec? {
        all.first { $0.name == name }
    }

    /// MCP 工具名的前缀（`--allowedTools "mcp__ccdesk__*"`）。
    public static let mcpServerName = "ccdesk"
}

/// press_key 支持的按键。
public enum AssistantKey: String, CaseIterable, Sendable {
    case enter, escape, ctrlC = "ctrl-c", up, down, tab

    /// 宽松解析（"Enter" / "esc" / "ctrl+c" / "^C"…）。
    public init?(spoken: String) {
        let k = spoken.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "-")
        switch k {
        case "enter", "return", "回车": self = .enter
        case "escape", "esc": self = .escape
        case "ctrl-c", "ctrl+c", "control-c", "^c", "ctrlc": self = .ctrlC
        case "up", "arrowup", "uparrow": self = .up
        case "down", "arrowdown", "downarrow": self = .down
        case "tab": self = .tab
        default: return nil
        }
    }

    /// 发给终端的字节；方向键随应用光标模式（DECCKM）变化。
    public func bytes(applicationCursor: Bool) -> String {
        switch self {
        case .enter: return "\r"
        case .escape: return "\u{1b}"
        case .ctrlC: return "\u{03}"
        case .up: return applicationCursor ? "\u{1b}OA" : "\u{1b}[A"
        case .down: return applicationCursor ? "\u{1b}OB" : "\u{1b}[B"
        case .tab: return "\t"
        }
    }
}
