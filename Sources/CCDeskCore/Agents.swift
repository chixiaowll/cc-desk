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
        return ["-l", "-i", "-c", "\(command); exec \"$SHELL\" -l -i"]
    }

    public static func environment(base: [String: String], shell: String, terminalID: UUID) -> [String] {
        var env = base.filter { !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "CLAUDECODE" }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["SHELL"] = shell
        env["CC_DESK"] = "1"
        env["CC_DESK_TERMINAL_ID"] = terminalID.uuidString
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// 写入终端的文本；bracketed paste 模式下包裹粘贴边界。
    public static func inputPayload(text: String, bracketed: Bool) -> String {
        bracketed ? "\u{1b}[200~\(text)\u{1b}[201~" : text
    }
}
