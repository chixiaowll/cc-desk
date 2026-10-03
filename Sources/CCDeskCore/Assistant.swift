import Foundation

// MARK: - 上下文

/// 语音助手（设计 §12）看到的一个侧栏会话。`id` 是给模型用的短 id（s1、s2…），`rowID` 是真实的侧栏行 id。
public struct AssistantSessionInfo: Equatable, Sendable {
    public let rowID: String
    public let title: String
    /// 项目目录名（分组标题）。
    public let dir: String
    public let agent: AgentKind
    public let status: AgentStatus
    public let isSelected: Bool

    public init(rowID: String, title: String, dir: String, agent: AgentKind, status: AgentStatus, isSelected: Bool) {
        self.rowID = rowID
        self.title = title
        self.dir = dir
        self.agent = agent
        self.status = status
        self.isSelected = isSelected
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
    public let title: String
    public let dir: String
    public let agent: AgentKind

    public init(sessionID: String, title: String, dir: String, agent: AgentKind) {
        self.sessionID = sessionID
        self.title = title
        self.dir = dir
        self.agent = agent
    }
}

/// 一次意图解析的完整上下文。模型只看到短 id；解析结果按这里的映射换回真实 id。
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
        self.sessions = Array(sessions.prefix(Self.maxSessions))
        var seen = Set<String>()
        self.projects = Array(projects.filter { seen.insert($0.path).inserted }.prefix(Self.maxProjects))
        self.history = Array(history.prefix(Self.maxHistory))
        self.pendingText = pendingText
        self.lastTurnSummary = lastTurnSummary
        self.language = language
    }

    public var selected: AssistantSessionInfo? { sessions.first(where: \.isSelected) }

    public func shortID(session index: Int) -> String { "s\(index + 1)" }
    public func shortID(history index: Int) -> String { "h\(index + 1)" }

    /// 短 id（或真实行 id）-> 会话。
    public func session(id: String) -> AssistantSessionInfo? {
        if let i = sessions.indices.first(where: { shortID(session: $0) == id }) { return sessions[i] }
        return sessions.first { $0.rowID == id }
    }

    public func historyItem(id: String) -> AssistantHistoryInfo? {
        if let i = history.indices.first(where: { shortID(history: $0) == id }) { return history[i] }
        return history.first { $0.sessionID == id }
    }

    /// 状态的英文代号（给模型看）。
    static func statusCode(_ status: AgentStatus) -> String {
        switch status {
        case .working: return "working"
        case .waiting: return "waiting_for_approval"
        case .idle: return "idle"
        case .ended: return "ended"
        case .unknown: return "unknown"
        }
    }

    /// 发给模型的上下文 JSON（键名固定、按字典序输出，便于测试）。
    public func json() -> String {
        var sessionList: [[String: Any]] = []
        for (i, s) in sessions.enumerated() {
            var item: [String: Any] = [
                "id": shortID(session: i), "title": Self.clip(s.title, Self.titleLimit), "dir": s.dir,
                "agent": s.agent.rawValue, "status": Self.statusCode(s.status), "isSelected": s.isSelected,
            ]
            if case .waiting(let reason?) = s.status { item["waitingFor"] = Self.clip(reason, Self.titleLimit) }
            sessionList.append(item)
        }
        var root: [String: Any] = [
            "sessions": sessionList,
            "projects": projects.map { ["name": $0.name, "path": $0.path] },
            "history": history.enumerated().map { i, h in
                ["id": shortID(history: i), "title": Self.clip(h.title, Self.titleLimit), "dir": h.dir, "agent": h.agent.rawValue]
            },
            "pendingText": Self.clip(pendingText, Self.pendingLimit),
            "uiLanguage": language,
        ]
        if let summary = lastTurnSummary, !summary.isEmpty { root["lastTurnSummary"] = Self.clip(summary, Self.summaryLimit) }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// 单行化并截断（超出时末尾加「…」）。
    public static func clip(_ s: String, _ limit: Int) -> String {
        let line = s.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}

// MARK: - 提示词

public enum AssistantPrompt {
    /// 意图解析的系统提示词。
    public static let intentSystem = """
    You are the voice-control router of CC Desk, a macOS app that hosts several coding-agent terminal sessions \
    (Claude Code, Codex, pi). The user speaks; each utterance is a speech-to-text transcript (it may contain \
    homophone errors). Decide what the utterance means and reply with ONE JSON object only, no prose, no code fence:
    {"action":"insert|send|cancel|approve|deny|switch|new|resume|close|query|answer|stop|none","args":{...},"speak":"..."}

    Actions:
    - insert {"text"}: content meant for the coding agent (a task, an instruction about code, an answer to the agent). \
    Put the cleaned utterance in text verbatim (fix obvious transcription errors, drop filler words; never summarize, \
    never translate, never answer it yourself). The text is typed into the agent's input box without sending.
    - send {}: submit the pending text ("发了吧", "提交", "send it").
    - cancel {}: discard the pending dictated text ("刚才那句不要了", "清掉").
    - approve {} / deny {}: answer the permission prompt of the SELECTED session (isSelected true). Only valid when \
    that selected session's status is waiting_for_approval; other sessions waiting does not count.
    - switch {"session_id"}: show another session ("切到 poems 那个").
    - new {"dir","agent"}: start a session; dir must be a path from projects; agent is claude, codex or pi \
    (default claude).
    - resume {"history_session_id"} or {"query"}: reopen a past session from history; use query (title keywords) \
    when no history entry clearly matches.
    - close {"session_id"}: close a session ("关掉这个会话"; "this" means the selected one).
    - query {"question","session_id"?}: a question about what a session did or is doing ("它在干嘛", \
    "刚才改了哪些文件", "测试过了吗"); session_id defaults to the selected one.
    - answer {"text"}: a question about CC Desk itself that the context answers ("有哪些会话", "几个在跑", \
    "poems 那个是什么状态", "现在选中的是哪个"). text is the spoken answer in the uiLanguage (zh-Hans: at most 80 \
    Chinese characters; en: at most 40 words): name sessions by dir and short title, say their status in plain words.
    - stop {}: leave conversation mode ("退出对话模式").
    - none {}: nothing to do (noise, chit-chat, thanks).

    Rules:
    - Content for the coding agent → insert. Controlling CC Desk → the matching action. If unsure → insert.
    - Relayed speech is content for the agent: "问他一下X" / "跟它说X" / "告诉它X" / "让它X" / "在终端里输入X" → \
    insert with text X. A question the user wants the agent to answer is insert, not query.
    - query only when the user asks CC Desk itself to report on a session ("它在干嘛", "它刚才改了哪些文件").
    - new only when the user explicitly asks to open/start a new session ("新开", "新建", "开一个").
    - none only for noise, thanks or chit-chat — never for an unclear request (unclear → insert).
    - "让它继续" / "continue": if the selected session is waiting_for_approval → approve; otherwise → insert with \
    text "继续" (the agent should keep going).
    - Only use session_id / history_session_id values that appear in the context. Match sessions by title, dir \
    name or agent; "this one"/"它"/"这个" means the selected session.
    - speak: a short natural spoken reply in the uiLanguage (zh-Hans: at most 20 Chinese characters; en: at most \
    12 words), no markdown, no paths. For insert, speak may be empty.
    """

    /// 常驻助手会话的系统提示词：一个会话里处理三种带标签的消息。
    public static let residentSystem = """
    You are the voice assistant of CC Desk, a macOS app that hosts several coding-agent terminal sessions \
    (Claude Code, Codex, pi). This is one long-running conversation: remember what the user said and what happened \
    earlier, and use it to resolve references like "刚才那句", "搞错了", "再说一遍", "它", "那个".
    Every user message starts with a tag:
    - [UTTERANCE]: a speech-to-text transcript to route. Reply with ONE JSON object as described below.
    - [SUMMARIZE]: summarize the given transcript tail of a session's last turn for someone listening: 1–2 short \
    spoken sentences (what it did, how it turned out, whether the user needs to act). Plain text, no markdown.
    - [QUESTION]: answer a spoken question about a session from the given transcript tail and status in 1–2 short \
    spoken sentences; if it does not say, say so. Plain text, no markdown.
    Plain-text replies use the uiLanguage (zh-Hans: Simplified Chinese, at most 60 characters; en: at most 35 words), \
    no code, no full paths (file names are fine), no lists.
    Messages may include "Events" (what CC Desk did since your last reply, e.g. text typed into a session locally) \
    and "Context" (the sidebar). "Context: unchanged" means the last Context you saw still holds, including ids. \
    Session ids are only valid for the latest Context.

    For [UTTERANCE]:

    """ + intentSystem

    /// 常驻会话里的一句话：标签 + 事件 + 话语 + 上下文（unchanged 时省略 JSON）。
    public static func residentUtterance(utterance: String, events: [String], contextJSON: String?) -> String {
        var lines = ["[UTTERANCE]"]
        if !events.isEmpty { lines.append("Events: " + events.joined(separator: "; ")) }
        lines.append("Utterance: \(AssistantContext.clip(utterance, 500))")
        lines.append("Context: " + (contextJSON ?? "unchanged"))
        return lines.joined(separator: "\n")
    }

    public static func residentSummary(title: String, digest: String, language: String) -> String {
        "[SUMMARIZE] uiLanguage=\(language)\n" + summaryMessage(title: title, digest: digest)
    }

    public static func residentQuestion(question: String, title: String, status: AgentStatus, digest: String,
                                        language: String) -> String {
        "[QUESTION] uiLanguage=\(language)\n" + queryMessage(question: question, title: title, status: status, digest: digest)
    }

    /// 每次调用的用户消息：话语 + 上下文 JSON。
    public static func intentMessage(utterance: String, context: AssistantContext) -> String {
        "Utterance: \(AssistantContext.clip(utterance, 500))\nContext: \(context.json())"
    }

    /// 回复摘要的系统提示词。
    public static func summarySystem(language: String) -> String {
        """
        You summarize a coding agent's last turn for a user who is listening, not reading. Given the tail of the \
        session transcript (USER / ASSISTANT / EDIT / RUN / OUTPUT / ERROR lines), say in 1–2 short spoken sentences \
        what the agent did in its last turn, how it turned out, and whether the user needs to do anything. \
        \(languageRule(language)) Plain text only: no markdown, no code, no full paths (file names are fine), no lists.
        """
    }

    public static func summaryMessage(title: String, digest: String) -> String {
        "Session: \(AssistantContext.clip(title, AssistantContext.titleLimit))\nTranscript tail:\n\(digest)"
    }

    /// 状态问答的系统提示词。
    public static func querySystem(language: String) -> String {
        """
        You answer a spoken question about a coding agent session. Use only the transcript tail provided \
        (USER / ASSISTANT / EDIT / RUN / OUTPUT / ERROR lines) and the session status. Answer in 1–2 short spoken \
        sentences; if the transcript does not say, say so briefly. \(languageRule(language)) Plain text only: no \
        markdown, no code, no full paths (file names are fine), no lists.
        """
    }

    public static func queryMessage(question: String, title: String, status: AgentStatus, digest: String) -> String {
        """
        Question: \(AssistantContext.clip(question, 300))
        Session: \(AssistantContext.clip(title, AssistantContext.titleLimit)) (status: \(AssistantContext.statusCode(status)))
        Transcript tail:
        \(digest)
        """
    }

    static func languageRule(_ language: String) -> String {
        language == "zh-Hans" ? "Reply in Simplified Chinese, at most 60 characters." : "Reply in English, at most 35 words."
    }
}

// MARK: - 模型输出

/// 校验后的助手指令（真实 id）。
public enum AssistantCommand: Equatable, Sendable {
    case insert(String)
    case send
    case cancel
    case approve
    case deny
    case switchTo(rowID: String)
    case new(dir: String, agent: AgentKind)
    case resume(sessionID: String)
    case close(rowID: String)
    case query(question: String, rowID: String?)
    case stop
    case none
}

public struct AssistantDecision: Equatable, Sendable {
    public let command: AssistantCommand
    /// 要播报的话（可能为空）。
    public let speak: String
    /// 模型输出无效，已退回为插入原话。
    public let isFallback: Bool

    public init(command: AssistantCommand, speak: String, isFallback: Bool = false) {
        self.command = command
        self.speak = speak
        self.isFallback = isFallback
    }
}

public enum AssistantResponse {
    public static let speakLimit = 40
    public static let actions: Set<String> = [
        "insert", "send", "cancel", "approve", "deny", "switch", "new", "resume", "close", "query", "answer", "stop", "none",
    ]

    /// 模型文字里的 JSON 对象：容忍 ```json 围栏与前后多余文字（取第一个 `{` 到最后一个 `}`）。
    public static func jsonObject(in text: String) -> [String: Any]? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.replacingOccurrences(of: #"^```[A-Za-z]*\s*"#, with: "", options: .regularExpression)
            body = body.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        guard let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(body[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
    }

    /// 严格校验模型输出；任何不合法（JSON 坏、未知 action、不存在的 id…）都退回为插入原话，并播报「没听懂，已填入」。
    public static func decide(modelText: String, utterance: String, context: AssistantContext) -> AssistantDecision {
        let fallback = AssistantDecision(command: .insert(utterance), speak: L("assistant.fallback"), isFallback: true)
        guard let obj = jsonObject(in: modelText), let action = (obj["action"] as? String)?.lowercased(),
              actions.contains(action) else { return fallback }
        let args = obj["args"] as? [String: Any] ?? [:]
        let speak = cleanSpeak(obj["speak"] as? String ?? "")
        func arg(_ key: String) -> String? {
            guard let v = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        let selected = context.selected

        switch action {
        case "insert":
            let text = arg("text") ?? utterance
            guard ConversationText.isMeaningful(text) else { return fallback }
            return AssistantDecision(command: .insert(text), speak: speak)
        case "send":
            return AssistantDecision(command: .send, speak: speak)
        case "cancel":
            return AssistantDecision(command: .cancel, speak: speak)
        case "approve", "deny":
            // 不在等批准时回车会把输入框里的内容发出去，Esc 会打断 agent：一律不执行。
            guard selected?.status.isWaiting == true else { return fallback }
            return AssistantDecision(command: action == "approve" ? .approve : .deny, speak: speak)
        case "switch":
            guard let id = arg("session_id"), let s = context.session(id: id) else { return fallback }
            return AssistantDecision(command: .switchTo(rowID: s.rowID), speak: speak)
        case "close":
            // 给了 id 就必须有效；没给时指选中的会话。
            let target = arg("session_id").map { context.session(id: $0) } ?? selected
            guard let s = target else { return fallback }
            return AssistantDecision(command: .close(rowID: s.rowID), speak: speak)
        case "new":
            let agent = arg("agent").flatMap { AgentKind(rawValue: $0.lowercased()) }.flatMap { $0.isAgent ? $0 : nil }
                ?? .claude
            guard let dir = resolveProject(arg("dir"), context: context) else { return fallback }
            return AssistantDecision(command: .new(dir: dir, agent: agent), speak: speak)
        case "resume":
            if let id = arg("history_session_id"), let h = context.historyItem(id: id) {
                return AssistantDecision(command: .resume(sessionID: h.sessionID), speak: speak)
            }
            let query = arg("query") ?? arg("history_session_id") ?? ""
            if let h = matchHistory(query, in: context.history) {
                return AssistantDecision(command: .resume(sessionID: h.sessionID), speak: speak)
            }
            return AssistantDecision(command: .none, speak: L("assistant.resume.notFound"))
        case "query":
            let question = arg("question") ?? utterance
            if let id = arg("session_id") {
                guard let s = context.session(id: id) else { return fallback }
                return AssistantDecision(command: .query(question: question, rowID: s.rowID), speak: speak)
            }
            return AssistantDecision(command: .query(question: question, rowID: selected?.rowID), speak: speak)
        case "answer":
            guard let text = cleanSpokenAnswer(arg("text") ?? (obj["speak"] as? String ?? "")) else { return fallback }
            return AssistantDecision(command: .none, speak: text)
        case "stop":
            return AssistantDecision(command: .stop, speak: speak)
        default:
            return AssistantDecision(command: .none, speak: speak)
        }
    }

    /// dir 必须是上下文里的项目路径（也接受项目名）；缺省时用选中会话所在的项目。
    static func resolveProject(_ dir: String?, context: AssistantContext) -> String? {
        guard let dir else {
            guard let selected = context.selected else { return nil }
            return context.projects.first { $0.name == selected.dir }?.path
        }
        let trimmed = dir.hasSuffix("/") && dir.count > 1 ? String(dir.dropLast()) : dir
        if let p = context.projects.first(where: { $0.path == trimmed }) { return p.path }
        return context.projects.first { $0.name.lowercased() == trimmed.lowercased() }?.path
    }

    /// 按标题关键词找历史会话：标题包含整个查询，或包含查询里的每个词。
    static func matchHistory(_ query: String, in history: [AssistantHistoryInfo]) -> AssistantHistoryInfo? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if let h = history.first(where: { $0.title.lowercased().contains(q) }) { return h }
        let words = q.split(whereSeparator: { $0 == " " }).map(String.init)
        guard words.count > 1 else { return nil }
        return history.first { h in words.allSatisfy { h.title.lowercased().contains($0) } }
    }

    /// 去掉 markdown 符号与多余空白，截断到 `speakLimit`。
    public static func cleanSpeak(_ s: String) -> String {
        var text = s.replacingOccurrences(of: #"[`*#_>]"#, with: "", options: .regularExpression)
        text = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return text.count > speakLimit ? String(text.prefix(speakLimit)) : text
    }

    /// 摘要 / 回答的文字：去掉围栏、markdown 与换行，截断到 `limit`。
    public static func cleanSpokenAnswer(_ s: String, limit: Int = 160) -> String? {
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

/// `claude -p --output-format json` 的输出：`{"type":"result","is_error":false,"result":"…","usage":{…}}`。
public struct AssistantEnvelope: Equatable, Sendable {
    public let result: String
    public let inputTokens: Int
    public let outputTokens: Int

    public static func parse(_ stdout: String) -> AssistantEnvelope? {
        // 输出可能夹带别的行（如警告），取最后一个能解析的 JSON 对象行。
        for line in stdout.split(whereSeparator: \.isNewline).reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String == "result" else { continue }
            guard obj["is_error"] as? Bool != true, let result = obj["result"] as? String else { return nil }
            let usage = obj["usage"] as? [String: Any] ?? [:]
            func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
            return AssistantEnvelope(result: result,
                                     inputTokens: int("input_tokens") + int("cache_read_input_tokens")
                                         + int("cache_creation_input_tokens"),
                                     outputTokens: int("output_tokens"))
        }
        return nil
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
