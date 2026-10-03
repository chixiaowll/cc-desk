import Foundation

// MARK: - 上下文

/// 语音助手（设计 §12/§13）看到的一个侧栏会话。`shortID` 是给模型用的稳定短 id（s1、s2…），`rowID` 是真实的侧栏行 id。
public struct AssistantSessionInfo: Equatable, Sendable {
    public let rowID: String
    public let shortID: String
    public let title: String
    /// 项目目录名（分组标题）。
    public let dir: String
    public let agent: AgentKind
    public let status: AgentStatus
    public let isSelected: Bool
    /// 在 CC Desk 内嵌终端里（false = 外部终端，只能读状态 / 接管）。
    public let isEmbedded: Bool

    public init(rowID: String, shortID: String = "", title: String, dir: String, agent: AgentKind, status: AgentStatus,
                isSelected: Bool, isEmbedded: Bool = true) {
        self.rowID = rowID
        self.shortID = shortID
        self.title = title
        self.dir = dir
        self.agent = agent
        self.status = status
        self.isSelected = isSelected
        self.isEmbedded = isEmbedded
    }

    func with(shortID: String) -> AssistantSessionInfo {
        AssistantSessionInfo(rowID: rowID, shortID: shortID, title: title, dir: dir, agent: agent, status: status,
                             isSelected: isSelected, isEmbedded: isEmbedded)
    }

    /// 给模型看的一项（list_sessions / 上下文共用）。
    public var json: JSONValue {
        var item: [String: JSONValue] = [
            "id": .string(shortID), "title": .string(AssistantContext.clip(title, AssistantContext.titleLimit)),
            "dir": .string(dir), "agent": .string(agent.rawValue), "status": .string(AssistantContext.statusCode(status)),
        ]
        if isSelected { item["selected"] = true }
        if !isEmbedded { item["embedded"] = false }
        if case .waiting(let reason?) = status { item["waitingFor"] = .string(AssistantContext.clip(reason, AssistantContext.titleLimit)) }
        return .object(item)
    }
}

/// 新建会话时可选的项目目录（侧栏分组根目录 / 最近目录）。
public struct AssistantProject: Equatable, Sendable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// 可恢复的历史会话。
public struct AssistantHistoryInfo: Equatable, Sendable {
    public let sessionID: String
    public let shortID: String
    public let title: String
    public let dir: String
    public let agent: AgentKind

    public init(sessionID: String, shortID: String = "", title: String, dir: String, agent: AgentKind) {
        self.sessionID = sessionID
        self.shortID = shortID
        self.title = title
        self.dir = dir
        self.agent = agent
    }

    public var json: JSONValue {
        ["id": .string(shortID), "title": .string(AssistantContext.clip(title, AssistantContext.titleLimit)),
         "dir": .string(dir), "agent": .string(agent.rawValue)]
    }
}

/// 发给助手的侧栏上下文。会话没有短 id 时按位置补 s1、s2…（测试 / 旧调用方）。
public struct AssistantContext: Equatable, Sendable {
    public static let maxSessions = 30
    public static let maxHistory = 15
    public static let maxProjects = 20
    public static let titleLimit = 40
    public static let pendingLimit = 400
    public static let summaryLimit = 300

    public let sessions: [AssistantSessionInfo]
    public let projects: [AssistantProject]
    public let history: [AssistantHistoryInfo]
    /// 本轮已口述、尚未发送的内容。
    public let pendingText: String
    /// 选中会话最近一轮的摘要（若有）。
    public let lastTurnSummary: String?
    /// 界面语言（"zh-Hans" / "en"）。
    public let language: String

    public init(sessions: [AssistantSessionInfo], projects: [AssistantProject] = [], history: [AssistantHistoryInfo] = [],
                pendingText: String = "", lastTurnSummary: String? = nil, language: String) {
        self.sessions = sessions.prefix(Self.maxSessions).enumerated().map { i, s in
            s.shortID.isEmpty ? s.with(shortID: "s\(i + 1)") : s
        }
        var seen = Set<String>()
        self.projects = Array(projects.filter { seen.insert($0.path).inserted }.prefix(Self.maxProjects))
        self.history = history.prefix(Self.maxHistory).enumerated().map { i, h in
            h.shortID.isEmpty ? AssistantHistoryInfo(sessionID: h.sessionID, shortID: "h\(i + 1)", title: h.title,
                                                     dir: h.dir, agent: h.agent) : h
        }
        self.pendingText = pendingText
        self.lastTurnSummary = lastTurnSummary
        self.language = language
    }

    public var selected: AssistantSessionInfo? { sessions.first(where: \.isSelected) }

    /// 状态的英文代号（给模型看）。
    public static func statusCode(_ status: AgentStatus) -> String {
        switch status {
        case .working: return "working"
        case .waiting: return "waiting_for_approval"
        case .idle: return "idle"
        case .ended: return "ended"
        case .unknown: return "unknown"
        }
    }

    /// 每句话附带的上下文 JSON（键按字典序）：会话、项目名、未发送的内容、界面语言。历史会话通过 list_history 工具取。
    public func json() -> String {
        var root: [String: JSONValue] = [
            "sessions": .array(sessions.map(\.json)),
            "projects": .array(projects.map { .string($0.name) }),
            "uiLanguage": .string(language),
        ]
        if !pendingText.isEmpty { root["pendingText"] = .string(Self.clip(pendingText, Self.pendingLimit)) }
        if let summary = lastTurnSummary, !summary.isEmpty { root["lastTurnSummary"] = .string(Self.clip(summary, Self.summaryLimit)) }
        return JSONValue.object(root).compact
    }

    /// 单行化并截断（超出时末尾加「…」）。
    public static func clip(_ s: String, _ limit: Int) -> String {
        let line = s.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}

// MARK: - 提示词

public enum AssistantPrompt {
    /// 系统提示词的版本：变了就换新的常驻会话（旧会话按旧提示词说话）。
    public static let residentVersion = 2

    /// 常驻助手会话的系统提示词（设计 §13）：用 CC Desk 的工具做事，最后的文字回复会被朗读。
    public static let residentSystem = """
    You are the voice assistant of CC Desk, a macOS app that hosts several coding-agent terminal sessions \
    (Claude Code, Codex, pi). The user talks to you by voice. This is one long-running conversation: remember what \
    was said and done earlier to resolve "刚才那句", "搞错了", "再说一遍", "它", "那个".

    Every user message starts with a tag:
    - [UTTERANCE]: a speech-to-text transcript (may contain homophone errors). Do what it asks using the ccdesk tools, \
    then reply.
    - [SUMMARIZE]: summarize the given transcript tail of a session's last turn in 1–2 short spoken sentences (what it \
    did, how it turned out, whether the user needs to act). Do not call tools.
    Messages may include "Events" (what happened in CC Desk since your last reply, e.g. the user typed into a session) \
    and "Context" (the sidebar sessions with ids, project names, pendingText = typed but not sent yet). \
    "Context: unchanged" means the last Context still holds. Session ids stay valid until a session closes.

    How to act on an [UTTERANCE]:
    - Use tools to do the work; several calls in one turn are fine. Call tools without commentary — only your final \
    reply after the last tool result is spoken. Act directly — tools that need the user's \
    confirmation ask the user themselves; if one returns "cancelled", just acknowledge briefly, do not ask again.
    - Anything that sounds like work for a coding agent (改 / 加 / 修 / 实现 / 写 / 看看 / 跑 / 测试 / 解释…, a \
    question for the agent, an answer to the agent) is content for the selected session (selected:true in the latest \
    Context): call type_text at once with submit=false. Do not ask which file or function — the agent knows its own \
    context; "这个" / "它" refer to what the agent is working on. Type the user's words \
    verbatim: fix obvious transcription errors and drop filler words, but never rephrase, expand, translate or \
    answer it yourself. Relayed speech ("问他一下X", "跟它说X", "告诉它X", "让它X") is content X for that session. \
    Use submit=true only when the user also says to send it ("…然后发出去", "直接发").
    - new_session only when explicitly asked ("新开", "新建", "开一个"; default agent claude). Its prompt is the \
    user's words for the new agent, verbatim like type_text (e.g. "让它看下 README" → prompt "看下 README").
    - "发了吧" / "提交" / "send it" → press_key enter in the session you last typed into (else the selected one). \
    "刚才那句不要了" / "清掉" → clear_input there.
    - Approve / deny a permission prompt → respond_approval, only for a session whose status is waiting_for_approval.
    - Questions to you about a session ("它在干嘛", "改了哪些文件", "测试过了吗") → read_transcript (what it did) \
    or read_screen (what it shows now), then answer from what you read. Answering never changes anything: no \
    switch_to, type_text or press_key while answering. Never guess.
    - If a tool returns candidates, ask which one in a short question. If a tool fails, say so briefly.
    - Noise, thanks or chit-chat → no tool, a very short reply.

    Your final text reply is spoken aloud: use the uiLanguage (zh-Hans: Simplified Chinese, at most 40 characters; \
    en: at most 25 words), plain spoken words, no markdown, no lists, no code, no paths, no session ids. For \
    [SUMMARIZE] at most 60 characters / 35 words.
    """

    /// 常驻会话里的一句话：标签 + 事件 + 话语 + 上下文（unchanged 时省略 JSON）。
    public static func residentUtterance(utterance: String, events: [String], contextJSON: String?) -> String {
        var lines = ["[UTTERANCE]"]
        if !events.isEmpty { lines.append("Events: " + events.joined(separator: "; ")) }
        lines.append("Utterance: \(AssistantContext.clip(utterance, 500))")
        lines.append("Context: " + (contextJSON ?? "unchanged"))
        return lines.joined(separator: "\n")
    }

    public static func residentSummary(title: String, digest: String, language: String) -> String {
        "[SUMMARIZE] uiLanguage=\(language)\nSession: \(AssistantContext.clip(title, AssistantContext.titleLimit))\n" +
            "Transcript tail:\n\(digest)"
    }
}

// MARK: - 朗读文字

public enum AssistantSpeech {
    /// 模型回复 → 朗读的文字：去掉围栏、markdown 与换行，截断到 `limit`；空时 nil。
    public static func clean(_ s: String, limit: Int = 160) -> String? {
        var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[`*#_>]"#, with: "", options: .regularExpression)
        text = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

// MARK: - claude -p 的 JSON 输出

/// `claude -p --output-format json|stream-json` 的结果行：`{"type":"result","is_error":false,"result":"…","usage":{…}}`。
public struct AssistantEnvelope: Equatable, Sendable {
    public let result: String
    /// 本轮所有模型调用的输入 token 合计（含缓存）。
    public let inputTokens: Int
    public let outputTokens: Int
    /// 最后一次模型调用的输入 token（= 当前上下文大小；多次调用工具时比合计小得多）。
    public let contextTokens: Int

    public init(result: String, inputTokens: Int, outputTokens: Int, contextTokens: Int? = nil) {
        self.result = result
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.contextTokens = contextTokens ?? inputTokens
    }

    public static func parse(_ stdout: String) -> AssistantEnvelope? {
        // 输出可能夹带别的行（如警告），取最后一个能解析的 JSON 对象行。
        for line in stdout.split(whereSeparator: \.isNewline).reversed() {
            guard let obj = JSONValue.parse(String(line)), obj["type"] == "result" else { continue }
            guard obj["is_error"]?.boolValue != true, let result = obj["result"]?.stringValue else { return nil }
            let usage = obj["usage"] ?? [:]
            func input(_ u: JSONValue) -> Int {
                ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + (u[$1]?.intValue ?? 0) }
            }
            let last = usage["iterations"]?.arrayValue?.last.map(input)
            return AssistantEnvelope(result: result, inputTokens: input(usage),
                                     outputTokens: usage["output_tokens"]?.intValue ?? 0, contextTokens: last)
        }
        return nil
    }
}

/// 一轮里模型「最后说的话」：stream-json 的 assistant 消息里，最后一次工具调用之后的文字。
/// haiku 有时在调用工具前先说一句「我来看看」，这些不该被朗读；result 字段会把它们拼在一起。
public struct AssistantTurnText: Equatable, Sendable {
    public private(set) var text = ""

    public init() {}

    /// 处理一条 stream-json 消息；非 assistant 消息忽略。
    public mutating func consume(_ message: JSONValue) {
        guard message["type"] == "assistant", let content = message["message"]?["content"]?.arrayValue else { return }
        for block in content {
            switch block["type"]?.stringValue {
            case "tool_use"?: text = ""
            case "text"?:
                if let t = block["text"]?.stringValue { text += (text.isEmpty ? "" : "\n") + t }
            default: break
            }
        }
    }

    /// 要朗读的回复：有工具调用之后的文字就用它，否则用 result。
    public func spoken(result: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? result : text
    }
}

// MARK: - 本地快速回答

public enum AssistantLocal {
    /// 「哪些在等我」类问题：不调用模型，直接从侧栏状态回答。
    public static func isWaitingQuestion(_ utterance: String) -> Bool {
        let n = ConversationCommands.normalize(utterance)
        let zh = ["哪些在等我", "哪个在等我", "谁在等我", "有没有在等我", "有谁在等我", "哪些会话在等我", "哪些在等",
                  "哪些需要我", "哪个需要我", "有没有需要我", "哪些等我", "什么在等我", "有什么在等我", "哪些在等批准", "谁在等批准"]
        let en = ["whatswaitingforme", "whoswaitingforme", "whatiswaitingforme", "whoiswaitingforme",
                  "anythingwaitingforme", "whichsessionsarewaiting", "whatswaiting", "anythingwaiting"]
        return zh.contains(where: n.contains) || en.contains(where: n.contains)
    }

    /// 「问他一下 X」「跟它说 X」「在终端里输入 X」：转述给 agent 的话，返回 X（直接填入，不调用模型）。
    public static func relayContent(_ utterance: String) -> String? {
        var text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        func strip(_ prefixes: [String]) -> Bool {
            for p in prefixes where text.hasPrefix(p) && text.count > p.count {
                text = String(text.dropFirst(p.count)).trimmingCharacters(in: relayTrim)
                return true
            }
            return false
        }
        for marker in ["终端里面输入", "终端里输入", "终端中输入", "终端输入"] {
            if let r = text.range(of: marker) {
                text = String(text[r.upperBound...]).trimmingCharacters(in: relayTrim)
                return ConversationText.isMeaningful(text) ? text : nil
            }
        }
        while strip(["我是说", "我说", "你", "帮我", "请", "麻烦", "那", "就"]) {}
        let relays = ["问他一下", "问它一下", "问一下他", "问一下它", "问问他", "问问它", "问他", "问它",
                      "跟他说", "跟它说", "和他说", "和它说", "告诉他", "告诉它", "对他说", "对它说",
                      "让他", "让它", "叫他", "叫它", "输入"]
        guard strip(relays) else { return nil }
        return ConversationText.isMeaningful(text) ? text : nil
    }

    static let relayTrim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,：:、"))

    /// 「有哪些会话」类问题：不调用模型，直接念出侧栏里的会话与状态。
    public static func isListQuestion(_ utterance: String) -> Bool {
        let n = ConversationCommands.normalize(utterance)
        let zh = ["有哪些会话", "哪些会话", "有几个会话", "几个会话", "列出会话", "列一下会话", "会话列表", "所有会话",
                  "有什么会话", "都有哪些会话", "开了哪些", "开着哪些", "有哪些session", "哪些session", "session列表",
                  "列出所有", "现在都有哪些", "现在有哪些"]
        let en = ["listsessions", "listthesessions", "whatsessions", "whichsessions", "howmanysessions", "listallsessions"]
        return zh.contains(where: n.contains) || en.contains(where: n.contains)
    }

    static let listLimit = 8

    public static func listAnswer(sessions: [AssistantSessionInfo]) -> String {
        guard !sessions.isEmpty else { return L("assistant.list.none") }
        let items = sessions.prefix(listLimit).map { s -> String in
            L("assistant.list.item", AssistantContext.clip(s.dir, 16), statusWord(s.status))
        }.joined(separator: L("assistant.list.separator"))
        let more = sessions.count > listLimit ? L("assistant.list.more", sessions.count - listLimit) : ""
        return L("assistant.list.summary", sessions.count, items) + more
    }

    static func statusWord(_ status: AgentStatus) -> String {
        switch status {
        case .working: return L("assistant.status.working")
        case .waiting: return L("assistant.status.waiting")
        case .idle: return L("assistant.status.idle")
        case .ended: return L("assistant.status.ended")
        case .unknown: return L("assistant.status.unknown")
        }
    }

    public static func waitingAnswer(sessions: [AssistantSessionInfo]) -> String {
        let waiting = sessions.filter(\.status.isWaiting)
        guard !waiting.isEmpty else { return L("assistant.waiting.none") }
        let names = waiting.prefix(3).map { AssistantContext.clip($0.title, 16) }.joined(separator: L("assistant.list.separator"))
        return waiting.count == 1 ? L("assistant.waiting.one", names) : L("assistant.waiting.many", waiting.count, names)
    }
}
