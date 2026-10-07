import Foundation

/// 从进程表中识别交互式的 Codex / pi 进程（Claude 由 `~/.claude/sessions` 登记文件给出，不在这里识别）。
///
/// 实测（codex-cli 0.160.0 / pi 0.73.1，Homebrew npm 安装）：
/// - codex：`node /opt/homebrew/bin/codex` 包装进程 + 子进程原生二进制 `.../vendor/<triple>/bin/codex`（comm 为完整路径）；
///   另有无 tty 的 `codex app-server ...` 守护进程。真正的会话进程是带 tty 的原生 `codex`。
/// - pi：node 程序把 process.title 设为 "pi"，comm 与 args 都显示为 "pi"。
public enum AgentProcessMatcher {
    /// codex 的非交互子命令；首个非选项参数是这些时不是交互会话。
    static let codexNonInteractive: Set<String> = [
        "exec", "e", "app-server", "mcp", "mcp-server", "login", "logout", "completion", "sandbox",
        "debug", "apply", "a", "cloud", "proto", "help", "features", "update", "responses-api-proxy",
        "stdio-to-uds", "generate-ts", "generate-json-schema",
    ]

    /// opencode 的非交互子命令（首个非选项参数）；`opencode [目录]`、`attach`、`pr` 是交互界面。
    static let openCodeNonInteractive: Set<String> = [
        "completion", "acp", "mcp", "run", "debug", "providers", "auth", "agent", "upgrade", "uninstall", "serve",
        "web", "models", "stats", "export", "import", "github", "session", "plugin", "plug", "db",
    ]

    /// pi 的非交互参数。
    static let piNonInteractiveFlags: Set<String> = ["-p", "--print", "--mode", "--export", "--help", "-h", "--version", "-v"]

    public static func kind(of p: ProcInfo) -> AgentKind? {
        guard p.tty != nil else { return nil }
        let exe = p.executableName
        let argv = p.argv
        if exe == "codex" {
            if let sub = argv.dropFirst().first(where: { !$0.hasPrefix("-") }), codexNonInteractive.contains(sub) {
                return nil
            }
            if argv.dropFirst().contains(where: { $0 == "--version" || $0 == "--help" || $0 == "-V" || $0 == "-h" }) {
                return nil
            }
            return .codex
        }
        if exe == "opencode" || ((exe == "node" || exe == "bun") && argv.count >= 2
                                  && (argv[1].hasSuffix("/opencode") || argv[1] == "opencode")) {
            let rest = exe == "opencode" ? Array(argv.dropFirst()) : Array(argv.dropFirst(2))
            if let sub = rest.first(where: { !$0.hasPrefix("-") }), openCodeNonInteractive.contains(sub) { return nil }
            if rest.contains(where: { ["-h", "--help", "-v", "--version"].contains($0) }) { return nil }
            return .opencode
        }
        let isPi: Bool
        if exe == "pi" {
            isPi = true
        } else if exe == "node" || exe == "bun", argv.count >= 2 {
            let script = argv[1]
            let base = script.split(separator: "/").last.map(String.init) ?? script
            isPi = base == "pi" || script.hasSuffix("pi-coding-agent/dist/cli.js")
        } else {
            isPi = false
        }
        if isPi {
            if argv.dropFirst().contains(where: { piNonInteractiveFlags.contains($0) }) { return nil }
            return .pi
        }
        return nil
    }

    /// 进程表中所有交互式 Codex / pi 进程，按 pid 升序。若某进程的祖先已被识别为同类 agent，则跳过（避免包装进程重复计数）。
    public static func agentProcesses(in table: ProcessTable) -> [(proc: ProcInfo, kind: AgentKind)] {
        var matched: [Int32: AgentKind] = [:]
        for (pid, p) in table.byPID {
            if let k = kind(of: p) { matched[pid] = k }
        }
        return matched.keys.sorted().compactMap { pid in
            guard let p = table.byPID[pid], let k = matched[pid] else { return nil }
            if table.ancestors(of: pid).contains(where: { matched[$0.pid] == k }) { return nil }
            return (p, k)
        }
    }

    /// 命令行里显式给出的会话：`codex resume <id>` / `pi --session <id|path>`。
    public static func sessionHint(kind: AgentKind, argv: [String]) -> String? {
        let rest = Array(argv.dropFirst())
        switch kind {
        case .codex:
            guard let i = rest.firstIndex(of: "resume") ?? rest.firstIndex(of: "fork"), i + 1 < rest.count else { return nil }
            let candidate = rest[i + 1]
            return candidate.hasPrefix("-") ? nil : candidate
        case .pi:
            guard let i = rest.firstIndex(of: "--session"), i + 1 < rest.count else { return nil }
            return rest[i + 1]
        case .opencode:
            guard let i = rest.firstIndex(where: { $0 == "--session" || $0 == "-s" }), i + 1 < rest.count,
                  !rest.contains("--fork") else { return nil }
            return rest[i + 1]
        case .claude, .other:
            return nil
        }
    }
}
