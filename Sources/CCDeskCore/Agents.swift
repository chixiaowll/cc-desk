import Foundation

public enum ShellQuote {
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// v1 只有 Claude；v1.1 增加 Codex / pi 时实现同一协议。
public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    func launchCommand() -> String
    func resumeCommand(sessionID: String) -> String
}

public struct ClaudeAdapter: AgentAdapter {
    public init() {}
    public var kind: AgentKind { .claude }
    public func launchCommand() -> String { "claude" }
    public func resumeCommand(sessionID: String) -> String { "claude --resume \(ShellQuote.quote(sessionID))" }
}

public enum LaunchSpec {
    /// 登录交互 shell；有命令时先运行命令，命令结束后留在交互 shell 中。
    public static func shellArgs(command: String?) -> [String] {
        guard let command else { return ["-l", "-i"] }
        return ["-l", "-i", "-c", "\(command)\nexec \"$SHELL\" -l -i"]
    }

    /// 会话级 Claude Code 变量：进程特有，不应被子终端继承。
    private static let sessionScopedDenylist: Set<String> = [
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

    public static func environment(base: [String: String], shell: String, terminalID: UUID,
                                    defaultLocale: String = LaunchSpec.defaultUTF8Locale()) -> [String] {
        var env = base.filter { key, _ in
            !sessionScopedDenylist.contains(key)
                && !hostTerminalIdentityDenylist.contains(key)
                && !hostTerminalIdentityPrefixes.contains { key.hasPrefix($0) }
        }
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
