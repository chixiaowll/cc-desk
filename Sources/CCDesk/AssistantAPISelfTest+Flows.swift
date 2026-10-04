import Foundation
import CCDeskCore

/// `--assistant-api-selftest` 的各个场景（见 `AssistantAPISelfTest`）。在主运行循环上依次执行。
enum AssistantAPISelfTestFlows {
    typealias Check = (Bool, String) -> Void
    typealias Wait = (TimeInterval, () -> Bool) -> Bool

    /// 假的工具宿主：与 App 的工具入口一样先过 `AssistantToolPolicy.check`，再「执行」。记下真正执行了的工具。
    final class FakeToolbox {
        var executed: [String] = []

        func call(_ name: String, _ arguments: [String: JSONValue], turn: AssistantTurn?,
                  done: @escaping (MCPServerCore.ToolOutcome) -> Void) {
            if let denial = AssistantToolPolicy.check(name, turn: turn?.kind) {
                return done(.init(text: denial, isError: true))
            }
            executed.append(name)
            switch name {
            case "list_sessions": done(.init(text: #"[{"id":"s1","dir":"poems","status":"working"}]"#))
            case "type_text": done(.init(text: "typed"))
            default: done(.init(text: "unknown method \(name)", isError: true))
            }
        }
    }

    static func run(base: URL, root: URL, check: Check, wait: Wait) {
        let toolbox = FakeToolbox()
        let store = AssistantChatHistoryStore(url: root.appendingPathComponent("assistant/api-history.json"))
        let endpoint = APIEndpoint(base: base, model: "mock-model", apiKey: AssistantAPISelfTest.key, label: "mock")
        func makeBackend(configured: Bool = true) -> APIAssistantBackend {
            APIAssistantBackend(store: store, endpoint: { configured ? endpoint : nil },
                                executor: { name, arguments, turn, done in toolbox.call(name, arguments, turn: turn, done: done) })
        }
        let backend = makeBackend()

        func ask(_ b: APIAssistantBackend, _ message: String, _ kind: AssistantTurnKind,
                 timeout: TimeInterval = 20) -> Result<AssistantReply, AssistantError>? {
            var result: Result<AssistantReply, AssistantError>?
            b.ask(message, turn: AssistantTurn(kind: kind, spokenAt: 1), timeout: timeout) { result = $0 }
            _ = wait(timeout + 5) { result != nil }
            return result
        }
        func text(_ r: Result<AssistantReply, AssistantError>?) -> String {
            if case .success(let reply)? = r { return reply.text }
            return "<\(String(describing: r))>"
        }

        // 1. 一句话 → list_sessions → 最后的文字。
        let generation0 = backend.generation
        let r1 = ask(backend, AssistantPrompt.residentUtterance(utterance: "SCENARIO list 有哪些会话", events: [],
                                                                contextJSON: "{}"), .utterance)
        check(text(r1).hasPrefix("LIST_OK [{\"id\":\"s1\""), "utterance → list_sessions → reply (\(text(r1).prefix(40)))")
        check(toolbox.executed == ["list_sessions"], "list_sessions ran once via the tool host")
        if case .success(let reply)? = r1 {
            check(reply.inputTokens == 220 && reply.outputTokens == 17, "token usage summed over requests")
        }

        // 2. [EVENT] 要 type_text：拒绝，不执行。
        let r2 = ask(backend, AssistantPrompt.residentEvent("SCENARIO event", language: "zh-Hans", contextJSON: nil), .event)
        check(text(r2).hasPrefix("EVENT_RESULT Error: type_text is not allowed"), "event turn: type_text rejected")
        check(!toolbox.executed.contains("type_text"), "event turn: type_text never executed")

        // 3. 参数不是 JSON。
        let r3 = ask(backend, "[UTTERANCE]\nSCENARIO malformed", .utterance)
        check(text(r3).contains("not valid JSON"), "malformed arguments → error result back to the model")
        check(toolbox.executed == ["list_sessions"], "malformed call did not run")

        // 4. HTTP 500。
        let turnsBefore = backend.turnCount
        let r4 = ask(backend, "[UTTERANCE]\nSCENARIO http500", .utterance)
        check(r4 == .failure(.api("HTTP 500")), "HTTP 500 → .api(HTTP 500) (\(String(describing: r4)))")
        check(backend.turnCount == turnsBefore, "failed turn is not added to the history")

        // 5. 超时后队列继续。
        let r5 = ask(backend, "[UTTERANCE]\nSCENARIO slow", .utterance, timeout: 1)
        check(r5 == .failure(.timeout), "slow reply → timeout")
        let r5b = ask(backend, "[UTTERANCE]\nSCENARIO auth", .utterance)
        check(text(r5b) == "AUTH_OK", "next request after a timeout works and sends the Bearer key")

        // 6. 历史写盘、读回、重置。
        check(wait(3) { FileManager.default.fileExists(atPath: store.url.path) }, "history saved")
        let mode = (try? FileManager.default.attributesOfItem(atPath: store.url.path))?[.posixPermissions] as? Int
        check(mode == 0o600, "history file is 0600")
        let reloaded = makeBackend()
        check(reloaded.turnCount == backend.turnCount && backend.turnCount == 4, "history reloaded (\(reloaded.turnCount) turns)")
        check(backend.generation > generation0, "generation bumped on load")
        let beforeReset = reloaded.generation
        reloaded.reset()
        check(reloaded.turnCount == 0 && reloaded.generation > beforeReset, "reset clears the history")
        check(wait(3) { !FileManager.default.fileExists(atPath: store.url.path) }, "reset removes the history file")

        // 7–8. 测试连接与模型列表。
        var probe: AssistantAPIProbe.Result?
        ChatHTTPClient.shared.probe(base: base, apiKey: AssistantAPISelfTest.key, model: "mock-model") { r, _ in probe = r }
        _ = wait(10) { probe != nil }
        check(probe == .ok(toolCalling: true, model: "mock-model"), "test connection: tool calling works")
        var models: Result<[String], ChatAPIError>?
        ChatHTTPClient.shared.fetchModels(base: base, apiKey: nil) { models = $0 }
        _ = wait(10) { models != nil }
        check((try? models?.get()) == ["mock-a", "mock-b"], "model list fetched and sorted")

        // 9. 接口版顾问。
        consult(base: base, root: root, endpoint: endpoint, check: check, wait: wait)

        // 10. 没配置。
        let r10 = ask(makeBackend(configured: false), "[UTTERANCE]\nhi", .utterance)
        check(r10 == .failure(.notInstalled), "not configured → .notInstalled (falls back to local rules)")

        // 11. 日志里没有密钥与消息内容。
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let diag = (try? String(contentsOf: AssistantDiag.url, encoding: .utf8)) ?? ""
        check(diag.contains("api assistant http 200"), "diagnostics record status codes")
        check(!diag.contains(AssistantAPISelfTest.key) && !diag.contains("SCENARIO") && !diag.contains("LIST_OK"),
              "diagnostics contain no key and no message contents")

        // 12. 健壮性。
        AssistantAPISelfTestRobustness.run(base: base, root: root, check: check, wait: wait)

        liveOllama(wait: wait)
    }

    private static func consult(base: URL, root: URL, endpoint: APIEndpoint, check: Check, wait: Wait) {
        let repo = root.appendingPathComponent("repo")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? "TOP-SECRET-OUTSIDE\n".write(to: root.appendingPathComponent("outside-secret.txt"), atomically: true, encoding: .utf8)
        try? "def add(a, b):\n    return a - b\n".write(to: repo.appendingPathComponent("calc.py"), atomically: true,
                                                         encoding: .utf8)
        _ = ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "init", "-q"], environment: nil, cwd: nil, timeout: 10)
        guard let sandbox = ConsultSandbox(project: repo.path) else { return check(false, "consult sandbox") }
        var ending: ConsultEnding?
        var progress = 0
        let run = APIConsultRun(endpoint: endpoint, sandbox: sandbox, question: "add() 为什么不对？", profile: nil,
                                language: "zh-Hans", onProgress: { progress = $0 }, completion: { ending = $0 })
        run.start()
        _ = wait(30) { ending != nil }
        guard case .finished(let outcome)? = ending else { return check(false, "consult finished (\(String(describing: ending)))") }
        check(outcome.answer.hasPrefix("结论：OK"), "consult: outside file rejected, project file / search / git read")
        check(ConsultAnswer.conclusion(outcome.answer) == "OK，add 用了减号。", "consult conclusion line")
        check(progress == 4 && outcome.turns == 2 && outcome.inputTokens == 1020, "consult progress and tokens recorded")
        check(outcome.denials == 1, "consult: one rejected call (the outside file)")

        var cancelled: ConsultEnding?
        let slow = APIConsultRun(endpoint: endpoint, sandbox: sandbox, question: "x", profile: nil, language: "en",
                                 timeout: 0.000_001, onProgress: { _ in }, completion: { cancelled = $0 })
        slow.start()
        _ = wait(5) { cancelled != nil }
        if case .timedOut? = cancelled { check(true, "consult timeout") } else { check(false, "consult timeout") }
    }

    private static func say(_ s: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((s + "\n").utf8))
    }

    /// 可选：本机 Ollama 有模型时，用第一个模型测一次真实的工具调用（不计入成败；没有模型就跳过，不会去拉模型）。
    private static func liveOllama(wait: Wait) {
        guard let base = URL(string: AssistantAPIPreset.ollama.baseURL) else { return }
        var models: Result<[String], ChatAPIError>?
        ChatHTTPClient.shared.fetchModels(base: base, apiKey: nil) { models = $0 }
        _ = wait(5) { models != nil }
        guard let first = (try? models?.get())?.first else {
            return say("SKIP live Ollama check (no local models)")
        }
        var probe: (AssistantAPIProbe.Result, TimeInterval)?
        ChatHTTPClient.shared.probe(base: base, apiKey: nil, model: first) { probe = ($0, $1) }
        _ = wait(120) { probe != nil }
        say("INFO live Ollama \(first): \(probe.map { "\($0.0) in \(String(format: "%.1f", $0.1))s" } ?? "no answer")")
    }
}
