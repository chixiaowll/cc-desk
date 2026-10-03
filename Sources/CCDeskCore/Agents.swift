import Foundation

public enum ShellQuote {
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// 各 agent 的启动 / 恢复命令。
public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    func launchCommand() -> String
    func resumeCommand(sessionID: String) -> String
}

extension AgentAdapter {
    /// 带第一句话启动（claude / codex / pi 都接受位置参数作为交互会话的第一条消息）。
    /// 去掉换行；以 `-` 开头时前面补空格，避免被当成选项。
    public func launchCommand(prompt: String?) -> String {
        let text = (prompt ?? "").components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return launchCommand() }
        return launchCommand() + " " + ShellQuote.quote(text.hasPrefix("-") ? " " + text : text)
    }
}

public struct ClaudeAdapter: AgentAdapter {
    public init() {}
    public var kind: AgentKind { .claude }
    public func launchCommand() -> String { "claude" }
    public func resumeCommand(sessionID: String) -> String { "claude --resume \(ShellQuote.quote(sessionID))" }
}

public struct CodexAdapter: AgentAdapter {
    public init() {}
    public var kind: AgentKind { .codex }
    public func launchCommand() -> String { "codex" }
    public func resumeCommand(sessionID: String) -> String { "codex resume \(ShellQuote.quote(sessionID))" }
}

/// pi：`pi --session <path|id>`（id 可为前缀；按当前目录查找会话，所以须在原 cwd 下执行）。
public struct PiAdapter: AgentAdapter {
    public init() {}
    public var kind: AgentKind { .pi }
    public func launchCommand() -> String { "pi" }
    public func resumeCommand(sessionID: String) -> String { "pi --session \(ShellQuote.quote(sessionID))" }
}

public enum AgentAdapters {
    /// 可启动的 agent 适配器；普通 shell 返回 nil。
    public static func adapter(for kind: AgentKind) -> AgentAdapter? {
        switch kind {
        case .claude: return ClaudeAdapter()
        case .codex: return CodexAdapter()
        case .pi: return PiAdapter()
        case .other: return nil
        }
    }
}

/// 新建会话时 agent 选项的可用性。
public enum AgentAvailability: Equatable, Sendable {
    case available
    /// 还在检测本机是否安装。
    case checking
    case notInstalled

    /// `installed` 为检测到的已安装 agent（codex / pi）；nil 表示检测尚未完成。Claude 始终可用。
    public static func of(_ kind: AgentKind, installed: Set<AgentKind>?) -> AgentAvailability {
        guard AgentAdapters.adapter(for: kind) != nil else { return .notInstalled }
        if kind == .claude { return .available }
        guard let installed else { return .checking }
        return installed.contains(kind) ? .available : .notInstalled
    }

    public var isEnabled: Bool { self == .available }

    public var hint: String? {
        switch self {
        case .available: return nil
        case .checking: return L("availability.checking")
        case .notInstalled: return L("availability.notInstalled")
        }
    }
}

/// 检测本机安装了哪些 agent 命令：在登录 shell 里执行 `command -v`，输出找到的命令名，每行一个。
public enum AgentProbe {
    public static let commands = ["codex", "pi"]

    public static var script: String {
        "for c in \(commands.joined(separator: " ")); do command -v \"$c\" >/dev/null 2>&1 && echo \"$c\"; done; true"
    }

    public static func parse(_ output: String) -> Set<AgentKind> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            let name = line.trimmingCharacters(in: .whitespaces)
            guard commands.contains(name) else { return nil }
            return AgentKind(rawValue: name)
        })
    }
}

public enum LaunchSpec {
    /// 登录交互 shell；有命令时先运行命令，命令结束后留在交互 shell 中。
    public static func shellArgs(command: String?) -> [String] {
        guard let command else { return ["-l", "-i"] }
        return ["-l", "-i", "-c", "\(command)\nexec \"$SHELL\" -l -i"]
    }

    /// 会话级 Claude Code / Codex 变量：进程特有，不应被子终端继承。
    private static let sessionScopedDenylist: Set<String> = [
        "CODEX_THREAD_ID",
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_SSE_PORT", "CLAUDE_PID", "CLAUDE_EFFORT",
    ]

    /// 宿主终端身份变量：会让子进程误以为自己运行在原宿主终端（Terminal/iTerm/VS Code/tmux/screen）中。
    private static let hostTerminalIdentityDenylist: Set<String> = [
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "__CFBundleIdentifier",
        "TMUX", "TMUX_PANE", "STY",
    ]

    private static let hostTerminalIdentityPrefixes = ["ITERM_", "VSCODE_"]

    /// 没有任何 `LANG`/`LC_ALL`/`LC_CTYPE` 时使用的默认 UTF-8 locale：优先沿用系统当前 locale
    /// （形如 "xx_YY"），否则退回 "en_US.UTF-8"。
    public static func defaultUTF8Locale() -> String {
        let identifier = Locale.current.identifier
        let pattern = "^[a-z]{2,3}_[A-Z]{2}$"
        if identifier.range(of: pattern, options: .regularExpression) != nil {
            return "\(identifier).UTF-8"
        }
        return "en_US.UTF-8"
    }

    /// 去掉会话级 Claude Code / Codex 变量与宿主终端身份变量（子进程不应以为自己嵌套在某个 agent / 终端里）。
    public static func sanitizedEnvironment(base: [String: String]) -> [String: String] {
        base.filter { key, _ in
            !sessionScopedDenylist.contains(key)
                && !hostTerminalIdentityDenylist.contains(key)
                && !hostTerminalIdentityPrefixes.contains { key.hasPrefix($0) }
        }
    }

    public static func environment(base: [String: String], shell: String, terminalID: UUID,
                                    defaultLocale: String = LaunchSpec.defaultUTF8Locale()) -> [String] {
        var env = sanitizedEnvironment(base: base)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["SHELL"] = shell
        env["CC_DESK"] = "1"
        env["CC_DESK_TERMINAL_ID"] = terminalID.uuidString
        env["TERM_PROGRAM"] = "CCDesk"
        if env["LANG"] == nil && env["LC_ALL"] == nil && env["LC_CTYPE"] == nil {
            env["LANG"] = defaultLocale
        }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// 写入终端的文本；bracketed paste 模式下包裹粘贴边界。文本中若恰好包含粘贴结束序列，
    /// 需先去除，否则会提前终止粘贴块，使之后的内容被当作按键注入。
    public static func inputPayload(text: String, bracketed: Bool) -> String {
        guard bracketed else { return text }
        let sanitized = text.replacingOccurrences(of: "\u{1b}[201~", with: "")
        return "\u{1b}[200~\(sanitized)\u{1b}[201~"
    }
}
