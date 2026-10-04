import Foundation
import CCDeskCore

/// `--assistant-api-selftest` 的健壮性场景（代码审查的修复）：
/// - 模型给 `{"count":1e30}`、服务端 usage 给 1e20：不崩溃；
/// - 慢服务：一轮按时以超时结束（循环自己的计时器，不等服务端）；
/// - 执行了会改变东西的工具（type_text）后请求失败：历史保留这一部分，下一轮模型看得到；
/// - 顾问读项目里的 FIFO：立即拒绝，不卡住；grep / git 输出超过上限时进程被终止。
enum AssistantAPISelfTestRobustness {
    typealias Check = AssistantAPISelfTestFlows.Check
    typealias Wait = AssistantAPISelfTestFlows.Wait

    /// 助手的脚本（nil = 交给原来的脚本）。
    static func respond(user: String, tools: [String], messages: [JSONValue]) -> MockChatServer.Response? {
        if user.contains("SCENARIO huge") {
            guard tools.isEmpty else { return MockChatServer.text("HUGE_OK " + tools[0]) }
            var response = MockChatServer.toolCalls([("list_sessions", #"{"count":1e30,"lines":-1e30}"#)])
            response.body = response.body.replacingOccurrences(of: #""prompt_tokens":120"#, with: #""prompt_tokens":1e20"#)
            return response
        }
        if user.contains("SCENARIO typefail") {
            return tools.isEmpty ? MockChatServer.toolCalls([("type_text", #"{"text":"继续"}"#)])
                : .init(status: 500, body: #"{"error":{"message":"boom after typing"}}"#)
        }
        if user.contains("SCENARIO recall") {
            // 上一轮（失败的那轮）的工具调用与结果、补的说明都在历史里。
            let kept = messages.contains { $0["role"] == "tool" && $0["content"]?.stringValue == "typed" }
            let note = messages.contains { $0["content"]?.stringValue == AssistantToolLoop.interruptedNote }
            let call = messages.contains { $0["tool_calls"]?.arrayValue?.first?["function"]?["name"] == "type_text" }
            return MockChatServer.text(kept && note && call ? "RECALL_OK" : "RECALL_MISSING")
        }
        if user.contains("SCENARIO stall") { return .init(status: 200, body: MockChatServer.text("late").body, delay: 6) }
        return nil
    }

    /// 顾问的脚本。
    static func consult(user: String, tools: [String]) -> MockChatServer.Response? {
        if user.contains("SCENARIO fifo") {
            return tools.isEmpty ? MockChatServer.toolCalls([("read_file", #"{"path":"pipe"}"#)])
                : MockChatServer.text("结论：" + tools[0])
        }
        if user.contains("SCENARIO stall") { return .init(status: 200, body: MockChatServer.text("late").body, delay: 6) }
        return nil
    }

    static func run(base: URL, root: URL, check: Check, wait: Wait) {
        let toolbox = AssistantAPISelfTestFlows.FakeToolbox()
        let store = AssistantChatHistoryStore(url: root.appendingPathComponent("robust/api-history.json"))
        let endpoint = APIEndpoint(base: base, model: "mock-model", apiKey: nil, label: "mock")
        let backend = APIAssistantBackend(store: store, endpoint: { endpoint },
                                          executor: { name, arguments, turn, done in
                                              toolbox.call(name, arguments, turn: turn, done: done)
                                          })
        func ask(_ message: String, timeout: TimeInterval = 20) -> Result<AssistantReply, AssistantError>? {
            var result: Result<AssistantReply, AssistantError>?
            backend.ask(message, turn: AssistantTurn(kind: .utterance, spokenAt: 1), timeout: timeout) { result = $0 }
            _ = wait(timeout + 5) { result != nil }
            return result
        }

        // 离谱的数字。
        let huge = ask("[UTTERANCE]\nSCENARIO huge")
        if case .success(let reply)? = huge {
            check(reply.text.hasPrefix("HUGE_OK") && reply.inputTokens < 1_000_000,
                  "tool args {count:1e30} and usage 1e20 handled without a crash (in=\(reply.inputTokens))")
        } else {
            check(false, "huge numbers (\(String(describing: huge)))")
        }
        let args = ToolArgs(["count": .number(1e30), "start_line": .number(1e30), "max_lines": .number(-1e30)])
        check(args.int("count") == nil && args.int("start_line") == nil, "ToolArgs.int(1e30) is nil")

        // 执行了 type_text 后失败：历史保留这一部分。
        let before = backend.turnCount
        let failed = ask("[UTTERANCE]\nSCENARIO typefail")
        check(failed == .failure(.api("HTTP 500")), "failure after a mutating tool → .api(HTTP 500)")
        check(toolbox.executed == ["list_sessions", "type_text"], "type_text ran once before the failure")
        check(backend.turnCount == before + 1, "failed turn with an executed tool is kept in the history")
        check((try? ask("[UTTERANCE]\nSCENARIO recall")?.get().text) == "RECALL_OK",
              "next turn sees the executed tool call, its result and the interruption note")
        check(toolbox.executed.filter { $0 == "type_text" }.count == 1, "type_text was not repeated")

        // 一轮按时超时：服务端 6 秒后才回，循环的计时器 1.5 秒到点。
        timedLoop(base: base, check: check, wait: wait)

        consultChecks(base: base, root: root, endpoint: endpoint, check: check, wait: wait)
        outputCap(check: check)
        pendingBackend(check: check, wait: wait)
    }

    /// 自动模式下 claude 还在解析：请求攒着，解析完才交给选出的后端（这里是仅本地规则）。
    private static func pendingBackend(check: Check, wait: Wait) {
        var resolved = false
        var decided = 0
        let pending = PendingAssistantBackend(
            prepare: { done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { resolved = true; done() } },
            decide: { decided += 1; return LocalAssistantBackend() })
        var result: Result<AssistantReply, AssistantError>?
        pending.ask("x", turn: AssistantTurn(kind: .utterance), timeout: 20) { result = $0 }
        check(result == nil && pending.heldCount == 1 && decided == 0, "undecided backend holds the request")
        _ = wait(5) { result != nil }
        check(resolved && decided == 1 && result == .failure(.notInstalled) && pending.heldCount == 0,
              "held request goes to the backend chosen after claude is resolved")
    }

    private static func timedLoop(base: URL, check: Check, wait: Wait) {
        let endpoint = APIEndpoint(base: base, model: "mock-model", apiKey: nil, label: "mock")
        var result: Result<AssistantToolLoop.Outcome, AssistantToolLoop.Failure>?
        let loop = AssistantToolLoop(model: "mock-model", prefix: [], user: .user("[UTTERANCE]\nSCENARIO stall"),
                                     tools: AssistantTools.all, timeout: 1.5, gate: { _ in nil },
                                     transport: ChatHTTPClient.shared.transport(endpoint: endpoint, purpose: "selftest"),
                                     executor: { _, _, done in done(.init(text: "ok")) })
        let started = Date()
        loop.start { result = $0 }
        _ = wait(8) { result != nil }
        let elapsed = Date().timeIntervalSince(started)
        if case .failure(.timeout)? = result, elapsed < 3 {
            check(true, String(format: "slow server: turn timed out on schedule (%.1fs of 1.5s)", elapsed))
        } else {
            check(false, "slow server timeout (\(String(describing: result)) after \(elapsed)s)")
        }
    }

    private static func consultChecks(base: URL, root: URL, endpoint: APIEndpoint, check: Check, wait: Wait) {
        let repo = root.appendingPathComponent("robust-repo")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = mkfifo(repo.appendingPathComponent("pipe").path, 0o600)
        guard let sandbox = ConsultSandbox(project: repo.path) else { return check(false, "robust sandbox") }

        // 顾问读 FIFO：立即拒绝。
        var ending: ConsultEnding?
        let started = Date()
        let run = APIConsultRun(endpoint: endpoint, sandbox: sandbox, question: "SCENARIO fifo", profile: nil,
                                language: "en", onProgress: { _ in }, completion: { ending = $0 })
        run.start()
        _ = wait(20) { ending != nil }
        let elapsed = Date().timeIntervalSince(started)
        if case .finished(let outcome)? = ending {
            check(outcome.answer.contains("not a regular file") && elapsed < 5,
                  String(format: "consult read_file on a FIFO rejected quickly (%.1fs)", elapsed))
        } else {
            check(false, "consult FIFO (\(String(describing: ending)))")
        }
        let direct = APIConsultRun.execute("git_log", ToolArgs(["count": .number(1e30)]), sandbox: sandbox)
        check(!direct.text.isEmpty, "consult git_log {count:1e30} handled without a crash")
        let search = APIConsultRun.execute("search", ToolArgs(["pattern": "x"]), sandbox: sandbox)
        check(search.text == "No matches.", "consult search skips the FIFO (\(search.text.prefix(60)))")

        // 顾问的总时长：服务端不回，按时以超时结束。
        var timed: ConsultEnding?
        let slowStarted = Date()
        let slow = APIConsultRun(endpoint: endpoint, sandbox: sandbox, question: "SCENARIO stall", profile: nil,
                                 language: "en", timeout: 1.5, onProgress: { _ in }, completion: { timed = $0 })
        slow.start()
        _ = wait(8) { timed != nil }
        let slowElapsed = Date().timeIntervalSince(slowStarted)
        if case .timedOut? = timed, slowElapsed < 3 {
            check(true, String(format: "consult deadline fires on schedule (%.1fs of 1.5s)", slowElapsed))
        } else {
            check(false, "consult deadline (\(String(describing: timed)) after \(slowElapsed)s)")
        }
    }

    /// 输出上限：`yes` 会一直输出，读到 1 MB 就终止它。
    private static func outputCap(check: Check) {
        let started = Date()
        let result = ProcessRunner.capture("/usr/bin/yes", [], environment: nil, cwd: nil, timeout: 10,
                                           maxOutputBytes: 1024 * 1024)
        let elapsed = Date().timeIntervalSince(started)
        if case .exited(let out) = result {
            check(out.truncated && out.stdout.utf8.count == 1024 * 1024 && elapsed < 5,
                  String(format: "process output capped at 1 MB and the process stopped (%.1fs)", elapsed))
        } else {
            check(false, "output cap (\(result))")
        }
    }
}
