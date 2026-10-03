import Foundation

/// 会话记录里对语音摘要 / 问答有用的一条：用户 / 助手文字、改动的文件、执行的命令、工具输出。
public enum DigestEntry: Equatable, Sendable {
    case user(String)
    case assistant(String)
    case edit(String)
    case command(String)
    case tool(String)
    case output(String, isError: Bool)

    var line: String {
        switch self {
        case .user(let s): return "USER: " + TurnDigest.clip(s, 400)
        case .assistant(let s): return "ASSISTANT: " + TurnDigest.clip(s, 700)
        case .edit(let s): return "EDIT: " + s
        case .command(let s): return "RUN: " + TurnDigest.clip(s, 200)
        case .tool(let s): return "TOOL: " + TurnDigest.clip(s, 120)
        case .output(let s, let error): return (error ? "ERROR: " : "OUTPUT: ") + TurnDigest.clip(s, 240)
        }
    }
}

/// 从 Claude / Codex / pi 会话记录尾部抽取紧凑的上下文（只读尾部 ≤256KB，输出 ≤ `maxChars`）。
///
/// - Claude：`{"type":"user"|"assistant","message":{"content":"…"|[{type:text|tool_use|tool_result,…}]}}`；
///   跳过 `isMeta` / `isSidechain` 与以 "<" 开头的注入块。
/// - Codex：`response_item` 的 `message`（user / assistant）、`function_call`（exec_command / shell / apply_patch）、
///   `custom_tool_call`（apply_patch）与 `*_output`。
/// - pi：`message` 的 user / assistant（text、toolCall）与 `toolResult`。
public enum TurnDigest {
    public static let tailBytes = 256 * 1024
    public static let defaultMaxChars = 6000

    public static func entries(kind: AgentKind, tail: Data) -> [DigestEntry] {
        var out: [DigestEntry] = []
        for line in TranscriptReader.lines(in: tail) {
            guard let obj = TranscriptReader.jsonObject(line) else { continue }
            switch kind {
            case .claude: out += claude(obj)
            case .codex: out += codex(obj)
            case .pi: out += pi(obj)
            case .other: break
            }
        }
        return out
    }

    /// 从最后一条往前取，直到总长度达到 `maxChars`；按时间顺序输出，每条一行。
    public static func digest(kind: AgentKind, tail: Data, maxChars: Int = defaultMaxChars) -> String {
        render(entries(kind: kind, tail: tail), maxChars: maxChars)
    }

    public static func render(_ entries: [DigestEntry], maxChars: Int = defaultMaxChars) -> String {
        var lines: [String] = []
        var total = 0
        for entry in entries.reversed() {
            let line = entry.line
            if total + line.count + 1 > maxChars { break }
            lines.append(line)
            total += line.count + 1
        }
        return lines.reversed().joined(separator: "\n")
    }

    // MARK: Claude

    static func claude(_ obj: [String: Any]) -> [DigestEntry] {
        guard obj["isMeta"] as? Bool != true, obj["isSidechain"] as? Bool != true,
              let type = obj["type"] as? String, let message = obj["message"] as? [String: Any] else { return [] }
        let content = message["content"]
        switch type {
        case "user":
            if let s = content as? String { return userText(s).map { [.user($0)] } ?? [] }
            guard let blocks = content as? [[String: Any]] else { return [] }
            return blocks.compactMap { b -> DigestEntry? in
                switch b["type"] as? String {
                case "text": return (b["text"] as? String).flatMap(userText).map(DigestEntry.user)
                case "tool_result":
                    return toolResultText(b["content"]).map { .output($0, isError: b["is_error"] as? Bool == true) }
                default: return nil
                }
            }
        case "assistant":
            guard let blocks = content as? [[String: Any]] else {
                return (content as? String).flatMap(nonEmpty).map { [.assistant($0)] } ?? []
            }
            return blocks.compactMap { b -> DigestEntry? in
                switch b["type"] as? String {
                case "text": return (b["text"] as? String).flatMap(nonEmpty).map(DigestEntry.assistant)
                case "tool_use":
                    return claudeTool(name: b["name"] as? String ?? "", input: b["input"] as? [String: Any] ?? [:])
                default: return nil
                }
            }
        default:
            return []
        }
    }

    static func claudeTool(name: String, input: [String: Any]) -> DigestEntry {
        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
            return .edit(path)
        case "Bash":
            return .command(input["command"] as? String ?? "")
        default:
            let detail = ["description", "pattern", "file_path", "path", "url", "query", "prompt"]
                .lazy.compactMap { input[$0] as? String }.first
            return .tool(detail.map { "\(name) \($0)" } ?? name)
        }
    }

    static func toolResultText(_ content: Any?) -> String? {
        if let s = content as? String { return nonEmpty(s) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        return nonEmpty(blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n"))
    }

    // MARK: Codex

    static func codex(_ obj: [String: Any]) -> [DigestEntry] {
        guard obj["type"] as? String == "response_item", let p = obj["payload"] as? [String: Any] else { return [] }
        switch p["type"] as? String {
        case "message":
            let role = p["role"] as? String
            guard role == "user" || role == "assistant", let parts = p["content"] as? [[String: Any]] else { return [] }
            let text = parts.compactMap { part -> String? in
                let t = part["type"] as? String
                return t == "input_text" || t == "output_text" || t == "text" ? part["text"] as? String : nil
            }.joined(separator: "\n")
            if role == "user" { return userText(text).map { [.user($0)] } ?? [] }
            return nonEmpty(text).map { [.assistant($0)] } ?? []
        case "function_call":
            let name = p["name"] as? String ?? ""
            let args = (p["arguments"] as? String).flatMap { TranscriptReader.jsonObject($0) } ?? [:]
            return codexTool(name: name, args: args, raw: p["arguments"] as? String)
        case "custom_tool_call":
            let name = p["name"] as? String ?? ""
            let input = p["input"] as? String ?? ""
            if name == "apply_patch" { return patchFiles(input).map(DigestEntry.edit) }
            return [.tool(name)]
        case "local_shell_call":
            let action = p["action"] as? [String: Any]
            return [.command(shellCommand(action?["command"]) ?? "")]
        case "function_call_output", "custom_tool_call_output":
            return codexOutput(p["output"]).map { [$0] } ?? []
        default:
            return []
        }
    }

    static func codexTool(name: String, args: [String: Any], raw: String?) -> [DigestEntry] {
        switch name {
        case "exec_command":
            let cmd = (args["cmd"] as? String) ?? shellCommand(args["cmd"]) ?? ""
            if cmd.contains("apply_patch") { return patchFiles(cmd).map(DigestEntry.edit) }
            return [.command(cmd)]
        case "shell", "container.exec", "local_shell":
            let cmd = shellCommand(args["command"]) ?? ""
            if cmd.contains("apply_patch") {
                let files = patchFiles(cmd)
                if !files.isEmpty { return files.map(DigestEntry.edit) }
            }
            return [.command(cmd)]
        case "apply_patch":
            return patchFiles((args["input"] as? String) ?? raw ?? "").map(DigestEntry.edit)
        default:
            return [.tool(name)]
        }
    }

    /// 输出可能是纯文本，也可能是 `{"output":"…","metadata":{"exit_code":N}}`。
    static func codexOutput(_ value: Any?) -> DigestEntry? {
        guard let s = value as? String else { return nil }
        if let obj = TranscriptReader.jsonObject(s), let out = obj["output"] as? String {
            let code = ((obj["metadata"] as? [String: Any])?["exit_code"] as? NSNumber)?.intValue ?? 0
            return nonEmpty(out).map { .output($0, isError: code != 0) }
        }
        let error = s.range(of: #"(?m)^(Process exited with code|Exit code:?)\s*[1-9]"#, options: .regularExpression) != nil
        return nonEmpty(s).map { .output($0, isError: error) }
    }

    static func shellCommand(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        guard let parts = value as? [String] else { return nil }
        // ["bash","-lc","<script>"] 只取脚本。
        if parts.count == 3, ["bash", "sh", "zsh"].contains(parts[0]), parts[1].hasPrefix("-") { return parts[2] }
        return parts.joined(separator: " ")
    }

    /// apply_patch 补丁里的 `*** Update File: path` / `*** Add File:` / `*** Delete File:`。
    static func patchFiles(_ patch: String) -> [String] {
        var files: [String] = []
        for line in patch.components(separatedBy: .newlines) {
            for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty, !files.contains(path) { files.append(path) }
            }
        }
        return files
    }

    // MARK: pi

    static func pi(_ obj: [String: Any]) -> [DigestEntry] {
        guard obj["type"] as? String == "message", let m = obj["message"] as? [String: Any] else { return [] }
        let content = m["content"]
        switch m["role"] as? String {
        case "user":
            if let s = content as? String { return userText(s).map { [.user($0)] } ?? [] }
            let text = (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
            return userText(text).map { [.user($0)] } ?? []
        case "assistant":
            if let s = content as? String { return nonEmpty(s).map { [.assistant($0)] } ?? [] }
            return (content as? [[String: Any]] ?? []).compactMap { b -> DigestEntry? in
                switch b["type"] as? String {
                case "text": return (b["text"] as? String).flatMap(nonEmpty).map(DigestEntry.assistant)
                case "toolCall":
                    return piTool(name: b["name"] as? String ?? "", args: b["arguments"] as? [String: Any] ?? [:])
                default: return nil
                }
            }
        case "toolResult":
            let text = (content as? String)
                ?? (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
            return nonEmpty(text).map { [.output($0, isError: m["isError"] as? Bool == true)] } ?? []
        default:
            return []
        }
    }

    static func piTool(name: String, args: [String: Any]) -> DigestEntry {
        switch name {
        case "write", "edit":
            return .edit((args["path"] as? String) ?? (args["file_path"] as? String) ?? "")
        case "bash":
            return .command(args["command"] as? String ?? "")
        default:
            let detail = ["path", "pattern", "query"].lazy.compactMap { args[$0] as? String }.first
            return .tool(detail.map { "\(name) \($0)" } ?? name)
        }
    }

    // MARK: 工具

    /// 用户消息：去掉空白；以 "<" 开头的是注入块（命令输出、环境信息、系统提醒），不算。
    static func userText(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("<") else { return nil }
        return t
    }

    static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 单行化（多个空白合并），超出 `limit` 时截断并加「…」。
    static func clip(_ s: String, _ limit: Int) -> String {
        let collapsed = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }
}
