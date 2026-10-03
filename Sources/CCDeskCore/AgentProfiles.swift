import Foundation

/// 专业 agent 配置（设计 §14）：`~/.cc-desk/agents/*.md`，格式同 Claude Code subagent——
/// YAML frontmatter（name / description / model / tools，另可加 title 作显示名）+ 正文（系统提示词）。
public struct AgentProfile: Equatable, Sendable {
    /// `--agent` 用的名字（小写字母、数字、连字符）。
    public let name: String
    /// 显示名（如「审查员」）；没有时用 name。
    public let title: String
    public let description: String
    /// sonnet / opus / haiku / 完整模型名；nil = 跟随 claude 默认。
    public let model: String?
    /// 允许的工具（Claude Code 工具名，可带 Bash(...) 规则）；空 = 继承全部。
    public let tools: [String]
    public let prompt: String
    /// 来源文件名（如 reviewer.md）。
    public let fileName: String

    public init(name: String, title: String? = nil, description: String, model: String?, tools: [String], prompt: String,
                fileName: String) {
        self.name = name
        self.title = (title?.isEmpty == false ? title : nil) ?? name
        self.description = description
        self.model = model
        self.tools = tools
        self.prompt = prompt
        self.fileName = fileName
    }

    /// 只读：声明了工具，且全部在只读集合里（Read / Grep / Glob / 只读 git）。可以用作后台顾问（consult）。
    public var isReadOnly: Bool {
        !tools.isEmpty && tools.allSatisfy(ConsultCommand.readOnlyTools.contains)
    }

    /// `claude --agents <json>` 的内容：`{"<name>": {"description","prompt","model"?,"tools"?}}`。
    public var agentsJSON: String {
        var item: [String: JSONValue] = ["description": .string(description), "prompt": .string(prompt)]
        if let model { item["model"] = .string(model) }
        if !tools.isEmpty { item["tools"] = .array(tools.map(JSONValue.string)) }
        return JSONValue.object([name: .object(item)]).compact
    }

    /// 给助手看的一项（list_agents）。
    public var json: JSONValue {
        var item: [String: JSONValue] = ["name": .string(name), "title": .string(title),
                                         "description": .string(AssistantContext.clip(description, 160)),
                                         "readOnly": .bool(isReadOnly)]
        if let model { item["model"] = .string(model) }
        return .object(item)
    }
}

public enum AgentProfileParser {
    public enum Failure: Error, Equatable {
        case noFrontmatter
        case missingName
        case invalidName(String)
        case emptyPrompt
    }

    /// 解析一个配置文件。frontmatter 只支持 `key: value`、`key: [a, b]` 与 `- item` 列表（够用的 YAML 子集）。
    public static func parse(_ text: String, fileName: String) -> Result<AgentProfile, Failure> {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[first].trimmingCharacters(in: .whitespaces) == "---",
              let end = lines[(first + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return .failure(.noFrontmatter) }
        let fields = frontmatter(Array(lines[(first + 1)..<end]))
        guard let name = fields.scalars["name"], !name.isEmpty else { return .failure(.missingName) }
        guard isValidName(name) else { return .failure(.invalidName(name)) }
        let prompt = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .failure(.emptyPrompt) }
        let tools = fields.lists["tools"] ?? fields.scalars["tools"].map(splitTools) ?? []
        let model = fields.scalars["model"].flatMap { $0.isEmpty || $0 == "inherit" ? nil : $0 }
        return .success(AgentProfile(name: name, title: fields.scalars["title"],
                                     description: fields.scalars["description"] ?? "", model: model,
                                     tools: tools, prompt: prompt, fileName: fileName))
    }

    /// 小写字母 / 数字 / 连字符，字母开头（与 Claude Code subagent 的 name 约定一致，也能安全地放进命令行）。
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[a-z][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil
    }

    struct Fields {
        var scalars: [String: String] = [:]
        var lists: [String: [String]] = [:]
    }

    static func frontmatter(_ lines: [String]) -> Fields {
        var fields = Fields()
        var listKey: String?
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("- "), let key = listKey {
                fields.lists[key, default: []].append(unquote(String(line.dropFirst(2))))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                listKey = key
                continue
            }
            listKey = nil
            if value.hasPrefix("["), value.hasSuffix("]") {
                fields.lists[key] = splitTools(String(value.dropFirst().dropLast()))
            } else {
                fields.scalars[key] = unquote(value)
            }
        }
        return fields
    }

    /// 逗号分隔的工具列表；括号里的逗号不算分隔（如 `Bash(git log:*)`）。
    static func splitTools(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var depth = 0
        for ch in s {
            switch ch {
            case "(": depth += 1; current.append(ch)
            case ")": depth = max(0, depth - 1); current.append(ch)
            case "," where depth == 0:
                out.append(current)
                current = ""
            default: current.append(ch)
            }
        }
        out.append(current)
        return out.map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let f = t.first, let l = t.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            return String(t.dropFirst().dropLast())
        }
        return t
    }
}

/// 配置目录：读取全部配置、首次安装内置配置（从不覆盖用户的修改；用户删掉的内置配置也不再装回）。
public struct AgentProfileStore: Sendable {
    public let directory: URL
    /// 记录已经装过的内置配置文件名（用户删除后不再自动装回）。
    var ledgerURL: URL { directory.appendingPathComponent(".installed-defaults") }

    public static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cc-desk/agents", isDirectory: true)
    }

    public init(directory: URL = AgentProfileStore.defaultDirectory) {
        self.directory = directory
    }

    /// 安装内置配置：文件不存在、且以前没装过时才写入。返回本次写入的文件名。
    @discardableResult
    public func installDefaults(_ defaults: [(fileName: String, contents: String)] = AgentProfileDefaults.all) -> [String] {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var ledger = Set((try? String(contentsOf: ledgerURL, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).map(String.init) ?? [])
        var installed: [String] = []
        for item in defaults {
            let url = directory.appendingPathComponent(item.fileName)
            if fm.fileExists(atPath: url.path) {
                ledger.insert(item.fileName)
                continue
            }
            guard !ledger.contains(item.fileName) else { continue }
            if (try? item.contents.write(to: url, atomically: true, encoding: .utf8)) != nil {
                installed.append(item.fileName)
                ledger.insert(item.fileName)
            }
        }
        try? (ledger.sorted().joined(separator: "\n") + "\n").write(to: ledgerURL, atomically: true, encoding: .utf8)
        return installed
    }

    /// 读取目录里的全部 `*.md`；解析失败的文件放进 `invalid`（文件名 + 原因）。名字重复时保留按文件名排序的第一个。
    public func load() -> (profiles: [AgentProfile], invalid: [(String, AgentProfileParser.Failure)]) {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.sorted()
        var profiles: [AgentProfile] = []
        var invalid: [(String, AgentProfileParser.Failure)] = []
        for file in files {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8) else { continue }
            switch AgentProfileParser.parse(text, fileName: file) {
            case .success(let p) where !profiles.contains(where: { $0.name == p.name }): profiles.append(p)
            case .success: continue
            case .failure(let f): invalid.append((file, f))
            }
        }
        return (profiles, invalid)
    }

    /// 按名字 / 显示名 / 文件名找配置（不区分大小写）。
    public static func find(_ ref: String, in profiles: [AgentProfile]) -> AgentProfile? {
        let r = ref.trimmingCharacters(in: .whitespaces).lowercased()
        guard !r.isEmpty else { return nil }
        return profiles.first { $0.name == r || $0.title.lowercased() == r || $0.fileName.lowercased() == r + ".md" }
            ?? profiles.first { $0.title.lowercased().contains(r) || r.contains($0.title.lowercased()) }
    }
}

/// 内置的两个专业 agent（随程序发布，首次运行时装进 ~/.cc-desk/agents/）。
public enum AgentProfileDefaults {
    public static let reviewer = """
    ---
    name: reviewer
    title: 审查员
    description: Reviews a project's uncommitted changes (or its most recent commits when the tree is clean) and reports concrete findings. Read-only.
    model: opus
    tools: Read, Grep, Glob, Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git show:*)
    ---
    You are a meticulous senior code reviewer. You only read; never try to modify files or run anything other than read-only git commands.

    1. Run `git status` and `git diff` (and `git diff --staged`). If there are no uncommitted changes, review the most recent commits instead (`git log -5 --stat`, then `git show` the relevant ones).
    2. Read the surrounding code with Read / Grep / Glob to understand the context of each change.
    3. Report findings ordered by severity: bugs and correctness problems first, then risky behavior, missing tests, and only then style. For each finding give the file and line, what is wrong, and a concrete fix.
    4. If everything looks good, say so briefly and mention what you checked.

    Answer in the language the user writes in. Keep it concise; no praise or filler.
    """

    public static let tester = """
    ---
    name: tester
    title: 测试员
    description: Runs the project's test suite and reports failures with their likely causes. Does not change code.
    model: sonnet
    tools: Read, Grep, Glob, Bash
    ---
    You are a test runner. Your job is to run the project's tests and explain the results; you do not edit code.

    1. Find out how this project runs its tests (README, package.json scripts, Makefile / justfile, Package.swift, Cargo.toml, pyproject.toml, go.mod…). Prefer the project's own documented command.
    2. Run the tests. If the full suite is very slow, run it anyway unless the user asked for a subset.
    3. Report: the command you ran, how many tests passed / failed / were skipped, and for each failure the test name, the key error lines, and the most likely cause (read the relevant code to back it up).
    4. Do not try to fix anything; suggest fixes in words only.

    Answer in the language the user writes in. Keep it concise.
    """

    public static let all: [(fileName: String, contents: String)] = [
        ("reviewer.md", reviewer),
        ("tester.md", tester),
    ]
}
