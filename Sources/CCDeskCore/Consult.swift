import Foundation

// MARK: - 顾问（设计 §14）：后台、只读、一次性的 claude -p

/// 顾问用的模型档位。默认 Sonnet；用户明确要求时才用 Opus。
public enum ConsultLevel: String, CaseIterable, Codable, Sendable {
    case sonnet, opus

    public init?(loose: String?) {
        guard let s = loose?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        if s.contains("opus") { self = .opus } else if s.contains("sonnet") { self = .sonnet } else { return nil }
    }

    public var displayName: String { self == .opus ? "Opus" : "Sonnet" }
}

/// 顾问的命令行（claude 2.1.280 实测，见设计 §14 实现记录）。
///
/// - `--restricted`：不读用户 / 项目 / 本地 settings（用户的 SessionStart 等 hook 不会运行，用户 settings 里的 allow
///   规则也不会放开写操作），文件工具限定在工作目录内。
/// - `--tools`：只有 Read / Grep / Glob / Bash 四个内置工具；`--allowedTools` 只放行只读工具与只读 git；
///   `--disallowedTools` 挡住 `git diff --output=<file>` 这类会写文件 / 执行外部程序（`--ext-diff`、`--textconv`）/
///   读工作目录以外文件（`--no-index`）的选项；仓库配置里的外部程序由环境变量覆盖（`GitSafety`）。
/// - `--permission-prompts none`：其他一切需要批准的调用自动拒绝，不会卡在权限提示上。
/// - `--strict-mcp-config`（没有 `--mcp-config`）：不加载任何 MCP 服务器。
/// - `--no-session-persistence`：不写会话记录；问题从 stdin 传入（避免被可变参数选项吞掉）。
public enum ConsultCommand {
    public static let readOnlyGit = ["Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)"]
    /// 只读工具集合（配置的 tools 全在这里面才算只读）。
    public static let readOnlyTools: Set<String> = Set(["Read", "Grep", "Glob"] + readOnlyGit)
    /// 只读 git 里仍会写文件 / 执行外部程序 / 读工作目录以外文件的选项。
    public static let disallowed = ["Bash(*--output*)", "Bash(*--ext-diff*)", "Bash(*--textconv*)", "Bash(*--no-index*)"]
    public static let timeout: TimeInterval = 300
    public static let maxConcurrent = 2

    /// 完整参数（不含可执行文件）。profile：只读的专业 agent 配置，其提示词追加到系统提示词，工具取交集。
    public static func arguments(level: ConsultLevel?, profile: AgentProfile?, language: String) -> [String] {
        let model = level?.rawValue ?? profile?.model ?? ConsultLevel.sonnet.rawValue
        var allowed = ["Read", "Grep", "Glob"] + readOnlyGit
        if let profile, !profile.tools.isEmpty { allowed = allowed.filter(profile.tools.contains) }
        if allowed.isEmpty { allowed = ["Read"] }
        var builtIn = ["Read", "Grep", "Glob"].filter(allowed.contains)
        if allowed.contains(where: { $0.hasPrefix("Bash(") }) { builtIn.append("Bash") }
        return ["-p", "--model", model, "--no-session-persistence",
                "--output-format", "stream-json", "--verbose",
                "--restricted", "--strict-mcp-config", "--permission-prompts", "none",
                "--tools", builtIn.joined(separator: ","),
                "--allowedTools", allowed.joined(separator: ","),
                "--disallowedTools", disallowed.joined(separator: ","),
                "--append-system-prompt", ConsultPrompt.system(language: language, profile: profile)]
    }

    /// 实际使用的模型名（显示用）。
    public static func model(level: ConsultLevel?, profile: AgentProfile?) -> String {
        level?.rawValue ?? profile?.model ?? ConsultLevel.sonnet.rawValue
    }
}

/// 顾问（以及助手的 git_status）运行 git 时的环境：「只读」的 git 命令也会按仓库自己的配置执行外部程序
/// （core.fsmonitor、diff.external、core.pager…），仓库可能不可信。用 `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` /
/// `GIT_CONFIG_VALUE_n`（优先级高于仓库配置）把这些项改成安全值：
/// - core.fsmonitor=false、core.pager=cat；GIT_PAGER / PAGER=cat；
/// - diff.external 改成一个只调用 /usr/bin/diff 的 shell 函数（空值会让每次 diff 失败），输出普通的统一格式差异；
/// - GIT_NO_REPLACE_OBJECTS=1、GIT_TERMINAL_PROMPT=0、GIT_OPTIONAL_LOCKS=0（git status 不写索引）。
/// 仓库配置里按驱动名定义的 textconv / filter 无法逐个覆盖（名字由 .gitattributes 决定），见设计 §14 的剩余风险。
public enum GitSafety {
    public static let externalDiff =
        #"f() { /usr/bin/diff -u --label "a/$1" --label "b/$1" "$2" "$5"; return 0; }; f"#

    public static let overrides: [(key: String, value: String)] = [
        ("core.fsmonitor", "false"),
        ("core.pager", "cat"),
        ("diff.external", externalDiff),
        ("core.hooksPath", "/dev/null"),
    ]

    /// 在 base 上加上安全设置（已有的 GIT_CONFIG_* 被替换）。
    public static func environment(_ base: [String: String]) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("GIT_CONFIG_KEY_") && !$0.key.hasPrefix("GIT_CONFIG_VALUE_") }
        env["GIT_CONFIG_PARAMETERS"] = nil
        env["GIT_CONFIG_COUNT"] = String(overrides.count)
        for (i, item) in overrides.enumerated() {
            env["GIT_CONFIG_KEY_\(i)"] = item.key
            env["GIT_CONFIG_VALUE_\(i)"] = item.value
        }
        env["GIT_NO_REPLACE_OBJECTS"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_PAGER"] = "cat"
        env["PAGER"] = "cat"
        env["GIT_EXTERNAL_DIFF"] = nil
        return env
    }
}

public enum ConsultPrompt {
    /// 追加到 Claude Code 默认系统提示词后面。
    public static func system(language: String, profile: AgentProfile?) -> String {
        let lang = language.hasPrefix("zh") ? "Simplified Chinese" : "English"
        let marker = language.hasPrefix("zh") ? "结论：" : "Conclusion:"
        var text = """
        You are a senior advisor consulted in the background by CC Desk's voice assistant. You can only read: Read, \
        Grep, Glob and read-only git commands (git status / diff / log / show). Never try to modify files, install \
        anything or run other commands — such calls are denied automatically and waste time. Investigate just enough \
        to answer well.

        Answer in \(lang). The FIRST line of your answer must be "\(marker) " followed by a 1–2 sentence answer that \
        works when read aloud (no code, no paths, no markdown). Then a blank line, then the details in concise \
        markdown (findings, file:line references, suggested next steps); keep the details under about 400 words \
        unless more is truly needed.
        """
        if let profile {
            text += "\n\nYou are acting as the \"\(profile.title)\" specialist:\n" + profile.prompt
        }
        return text
    }

    /// 发给顾问的问题（经 stdin）。
    public static func question(_ question: String, project: String?) -> String {
        var lines = ["Question: " + question.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let project { lines.append("Project directory (your working directory): " + project) }
        return lines.joined(separator: "\n")
    }
}

/// 顾问进程的结果（stream-json 的最后一个 result 行）。
public struct ConsultOutcome: Equatable, Codable, Sendable {
    public var answer: String
    public var isError: Bool
    public var inputTokens: Int
    public var outputTokens: Int
    public var durationMS: Int
    public var turns: Int
    /// 被拒绝的工具调用数（试图写文件 / 运行其他命令）。
    public var denials: Int

    public init(answer: String, isError: Bool = false, inputTokens: Int = 0, outputTokens: Int = 0, durationMS: Int = 0,
                turns: Int = 0, denials: Int = 0) {
        self.answer = answer
        self.isError = isError
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.durationMS = durationMS
        self.turns = turns
        self.denials = denials
    }

    /// 解析一行 stream-json；不是 result 行时 nil。
    public static func parse(line: String) -> ConsultOutcome? {
        guard let obj = JSONValue.parse(line), obj["type"] == "result" else { return nil }
        let usage = obj["usage"] ?? [:]
        let input = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            .reduce(0) { $0 + (usage[$1]?.intValue ?? 0) }
        let isError = obj["is_error"]?.boolValue == true || obj["subtype"]?.stringValue.map { $0 != "success" } == true
        return ConsultOutcome(answer: obj["result"]?.stringValue ?? "", isError: isError, inputTokens: input,
                              outputTokens: usage["output_tokens"]?.intValue ?? 0,
                              durationMS: obj["duration_ms"]?.intValue ?? 0, turns: obj["num_turns"]?.intValue ?? 0,
                              denials: obj["permission_denials"]?.arrayValue?.count ?? 0)
    }

    /// stream-json 里一条 assistant 消息中的工具调用数（进度显示用）。
    public static func toolCalls(line: String) -> Int {
        guard line.contains("\"tool_use\""), let obj = JSONValue.parse(line), obj["type"] == "assistant",
              let content = obj["message"]?["content"]?.arrayValue else { return 0 }
        return content.filter { $0["type"] == "tool_use" }.count
    }
}

public enum ConsultAnswer {
    static let markers = ["结论：", "结论:", "Conclusion:", "conclusion:", "**结论**：", "**Conclusion:**", "**结论：**"]

    /// 朗读用的一两句结论：首行的「结论：」之后的文字；没有标记时取开头一两句。
    public static func conclusion(_ answer: String, limit: Int = 160) -> String {
        let lines = answer.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines.prefix(3) {
            for marker in markers where line.hasPrefix(marker) {
                let rest = line.dropFirst(marker.count).trimmingCharacters(in: CharacterSet(charactersIn: " *"))
                if !rest.isEmpty { return AssistantContext.clip(rest, limit) }
            }
        }
        let text = lines.first.map { $0.replacingOccurrences(of: #"^[#>*\-\s]+"#, with: "", options: .regularExpression) } ?? ""
        return AssistantContext.clip(text, limit)
    }

    /// 结果面板里显示的正文：去掉首行结论（面板单独显示结论）。
    public static func details(_ answer: String) -> String {
        var lines = answer.components(separatedBy: .newlines)
        if let i = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           markers.contains(where: lines[i].trimmingCharacters(in: .whitespaces).hasPrefix) {
            lines.removeSubrange(0...i)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 顾问任务记录

public struct ConsultJob: Equatable, Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case running, done, failed, cancelled, timedOut
    }

    /// 给助手用的短 id（c1、c2…）。
    public let id: String
    public let question: String
    public let model: String
    public let profile: String?
    /// 项目目录（工作目录）。
    public let project: String
    public let startedAt: Date
    public var state: State
    public var finishedAt: Date?
    public var outcome: ConsultOutcome?
    /// 失败原因。
    public var error: String?
    /// 运行中已调用的工具数（进度）。
    public var toolCalls: Int

    public init(id: String, question: String, model: String, profile: String?, project: String, startedAt: Date,
                state: State = .running) {
        self.id = id
        self.question = question
        self.model = model
        self.profile = profile
        self.project = project
        self.startedAt = startedAt
        self.state = state
        self.toolCalls = 0
    }

    public var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }

    /// 给助手看的一项（list_consults）。
    public var json: JSONValue {
        var item: [String: JSONValue] = ["id": .string(id), "question": .string(AssistantContext.clip(question, 120)),
                                         "model": .string(model), "state": .string(state.rawValue),
                                         "project": .string(URL(fileURLWithPath: project).lastPathComponent)]
        if let outcome, state == .done { item["conclusion"] = .string(ConsultAnswer.conclusion(outcome.answer)) }
        if let error { item["error"] = .string(AssistantContext.clip(error, 120)) }
        return .object(item)
    }
}

/// 顾问任务簿：短 id、并发上限、结束状态、保留最近若干条（持久化供结果面板使用）。纯数据，调用方负责线程。
public struct ConsultBook: Equatable, Codable, Sendable {
    public static let keep = 20
    public private(set) var jobs: [ConsultJob] = []
    private var nextNumber = 1

    public init() {}

    public enum StartError: Error, Equatable {
        case tooMany(running: [String])
    }

    public var running: [ConsultJob] { jobs.filter { $0.state == .running } }

    /// 登记一个新任务；已有 `maxConcurrent` 个在运行时拒绝。
    public mutating func start(question: String, model: String, profile: String?, project: String, now: Date,
                               maxConcurrent: Int = ConsultCommand.maxConcurrent) -> Result<ConsultJob, StartError> {
        let active = running
        guard active.count < maxConcurrent else { return .failure(.tooMany(running: active.map(\.id))) }
        let job = ConsultJob(id: "c\(nextNumber)", question: question, model: model, profile: profile, project: project,
                             startedAt: now)
        nextNumber += 1
        jobs.insert(job, at: 0)
        prune()
        return .success(job)
    }

    /// 结束一个仍在运行的任务；已结束（如已取消）时忽略，返回 nil。
    @discardableResult
    public mutating func finish(_ id: String, state: ConsultJob.State, outcome: ConsultOutcome? = nil, error: String? = nil,
                                now: Date) -> ConsultJob? {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .running, state != .running else { return nil }
        jobs[i].state = state
        jobs[i].finishedAt = now
        jobs[i].outcome = outcome
        jobs[i].error = error
        return jobs[i]
    }

    public mutating func progress(_ id: String, toolCalls: Int) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .running else { return }
        jobs[i].toolCalls = toolCalls
    }

    public func job(_ id: String) -> ConsultJob? {
        let key = id.trimmingCharacters(in: .whitespaces).lowercased()
        return jobs.first { $0.id == key }
    }

    /// 读回持久化的记录：上次退出时还在运行的任务标为失败（进程已不在）。
    public mutating func recoverAfterRestart(now: Date) {
        for i in jobs.indices where jobs[i].state == .running {
            jobs[i].state = .failed
            jobs[i].finishedAt = now
            jobs[i].error = "CC Desk quit before it finished"
        }
    }

    private mutating func prune() {
        guard jobs.count > Self.keep else { return }
        // 运行中的永远保留；其余按新旧保留。
        var kept: [ConsultJob] = []
        var others = 0
        for job in jobs {
            if job.state == .running { kept.append(job); continue }
            if others < Self.keep - running.count { kept.append(job); others += 1 }
        }
        jobs = kept
    }
}
