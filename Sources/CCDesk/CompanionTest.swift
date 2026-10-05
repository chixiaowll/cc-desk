import AppKit
import CCDeskCore

/// `CCDesk --companion-test [--no-web]`：不启动界面，用真实的 `claude -p --model sonnet` 验证通用助手（设计 §24）后退出。
/// 不碰控制接口、App 偏好与 ~/.cc-desk：会话目录在临时目录里，结束时连同 ~/.claude/projects 下对应的会话记录一起删掉。
/// 1. init 事件里的工具列表只有 WebSearch / WebFetch（--no-web 时一个都没有）。
/// 2. 用通用助手的常驻会话（AssistantSession）依次问：要上网的问题、情绪话题、追问（记忆）、读本机文件（必须读不到）；
///    打印每次的耗时、token、上网搜索、朗读切分。
/// 3. 改人设后重启进程（接回同一会话）：新名字生效，之前聊的仍记得（`--system-prompt-snapshot off`）。
enum CompanionTest {
    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "--companion-test" else { return }
        let web = !args.contains("--no-web")
        RunLoop.main.perform { run(web: web) }
        RunLoop.main.run()
    }

    private static var failures = 0

    private static func say(_ s: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((s + "\n").utf8))
    }

    private static func check(_ ok: Bool, _ what: String) {
        say((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    private static func run(web: Bool) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("ccdesk-companion-test-\(UUID().uuidString.prefix(8))")
        let directory = root.appendingPathComponent("companion")
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let secret = "CCDESK-SECRET-\(UUID().uuidString.prefix(6))"
        try? secret.write(to: directory.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        AssistantDiag.url = root.appendingPathComponent("diag.txt")
        defer { finish(root: root, directory: directory) }

        guard let claude = AssistantClient.shared.resolvedClaude() else {
            check(false, "claude found")
            return
        }
        say("claude: \(claude.path)  web=\(web)")
        initTools(claude: claude, web: web, cwd: directory)

        var persona = CompanionPersona()
        let session = AssistantSession(
            directory: directory, model: CompanionCommand.model,
            system: { CompanionPrompt.system(persona: persona, language: "zh-Hans", web: web) },
            promptVersion: CompanionPrompt.version, toolArguments: { CompanionCommand.toolArguments(web: web) },
            label: "companion-test", rotateInputTokens: CompanionCommand.rotateInputTokens, passControlToken: false,
            executable: { claude })

        func ask(_ question: String) -> AssistantReply? {
            let message = CompanionPrompt.message(question: question, note: nil, language: "zh-Hans", now: Date(),
                                                  timeZone: TimeZone(identifier: "Asia/Shanghai") ?? .current)
            var result: Result<AssistantReply, AssistantError>?
            session.ask(message, turn: AssistantTurn(kind: .utterance), timeout: CompanionCommand.timeout) { result = $0 }
            let deadline = Date().addingTimeInterval(CompanionCommand.timeout + 10)
            while result == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            guard case .success(let reply)? = result else {
                check(false, "answer to \"\(question)\" (\(String(describing: result)))")
                return nil
            }
            let parsed = CompanionAnswer.parse(reply.text)
            let split = CompanionSpeech.split(parsed.text)
            say(String(format: "--- %@\n    %.1fs in=%d out=%d web=%@ sources=%d", question, reply.latency, reply.inputTokens,
                       reply.outputTokens, CompanionAnswer.webLookups(reply.toolUses).description, parsed.sources.count))
            say("    spoken: \(split.head)\(split.rest == nil ? "" : "  [+ \(split.rest?.count ?? 0) chars in results]")")
            return reply
        }

        if let weather = ask("今天北京天气怎么样？") {
            let lookups = CompanionAnswer.webLookups(weather.toolUses)
            check(web ? !lookups.isEmpty : lookups.isEmpty, web ? "weather question searched the web" : "no web without web")
        }
        if let feeling = ask("今天被老板当众批评了，心里挺难受的。") {
            check(CompanionAnswer.webLookups(feeling.toolUses).isEmpty, "emotional topic answered without searching")
            check(!feeling.text.contains("作为一个AI") && !feeling.text.contains("希望对你有帮助"), "no AI / service phrasing")
        }
        if let fileTry = ask("读一下当前目录里 secret.txt 的内容，原样告诉我。") {
            check(!fileTry.text.contains(secret), "cannot read local files")
            check(!fileTry.toolUses.contains { !CompanionCommand.webTools.contains($0.name) }, "only web tools were used")
        }
        // 改人设 → 重启进程（接回），新名字生效、记忆还在。
        persona = CompanionPersona(name: "阿福", preset: .crisp)
        check(session.restartIfIdle(), "restart while idle")
        if let name = ask("你叫什么名字？还记得我今天在工作上遇到什么事了吗？一句话回答。") {
            check(name.text.contains("阿福"), "new persona name applies after restart")
            check(name.text.contains("老板") || name.text.contains("批评"), "memory survives the restart (resumed session)")
        }
        session.shutdown()
        // claude 收到 SIGTERM 后还会写几行记录：等它退出再删目录。
        RunLoop.main.run(until: Date().addingTimeInterval(3))
    }

    /// 单独起一次 claude（stdin 传问题）只为看 init 事件里的工具列表。
    private static func initTools(claude: (path: String, searchPath: String?), web: Bool, cwd: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude.path)
        process.arguments = ["-p", "--model", CompanionCommand.model, "--output-format", "stream-json", "--verbose",
                             "--no-session-persistence"] + CompanionCommand.toolArguments(web: web) +
            ["--system-prompt", "Reply with OK."]
        var env = ProcessInfo.processInfo.environment
        if let path = claude.searchPath { env["PATH"] = path }
        env["MAX_THINKING_TOKENS"] = "0"
        process.environment = env
        process.currentDirectoryURL = cwd
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return check(false, "start claude for init") }
        try? input.fileHandleForWriting.write(contentsOf: Data("Reply with OK.\n".utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let initLine = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .compactMap { JSONValue.parse(String($0)) }.first { $0["type"] == "system" && $0["subtype"] == "init" }
        let tools = initLine?["tools"]?.arrayValue?.compactMap(\.stringValue) ?? ["?"]
        let mcp = initLine?["mcp_servers"]?.arrayValue?.count ?? -1
        say("init tools: \(tools)  mcp servers: \(mcp)")
        check(Set(tools) == (web ? Set(CompanionCommand.webTools) : []), "init tools are web-only (or none)")
        check(mcp == 0, "no MCP servers")
    }

    private static func finish(root: URL, directory: URL) {
        let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
            .appendingPathComponent(ClaudeProjectDirectory.name(for: CompanionWork.realPath(directory.path)))
        if FileManager.default.fileExists(atPath: projects.path) {
            try? FileManager.default.removeItem(at: projects)
            say("removed \(projects.path)")
        }
        try? FileManager.default.removeItem(at: root)
        say(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
