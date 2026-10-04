import XCTest
@testable import CCDeskCore

/// 接口后端的一轮（设计 §22）：用假的传输层按脚本回复，检查工具循环、权限、迭代上限、超时与取消。
final class AssistantToolLoopTests: XCTestCase {
    /// 按顺序回复脚本里的结果；记下每次请求体。回调同步（循环不依赖线程）。
    private final class FakeTransport {
        var script: [Result<ChatCompletion, ChatAPIError>]
        var bodies: [JSONValue] = []
        var timeouts: [TimeInterval] = []
        var cancelled = 0
        /// 不回复（模拟挂起的请求）。
        var hang = false
        var onSend: (() -> Void)?

        init(_ script: [Result<ChatCompletion, ChatAPIError>]) {
            self.script = script
        }

        var transport: AssistantToolLoop.Transport {
            { [self] body, timeout, completion in
                bodies.append(body)
                timeouts.append(timeout)
                onSend?()
                if !hang {
                    let next = script.isEmpty ? .failure(.invalidResponse("script exhausted")) : script.removeFirst()
                    completion(next)
                }
                return { [self] in cancelled += 1 }
            }
        }

        /// 第 n 次请求里的消息。
        func messages(_ n: Int) -> [JSONValue] { bodies[n]["messages"]?.arrayValue ?? [] }
    }

    private func call(_ name: String, _ args: String = "{}", id: String = "c1") -> ChatCompletion {
        ChatCompletion(content: "我来看看", toolCalls: [ChatToolCall(id: id, name: name, arguments: args)],
                       finishReason: "tool_calls", promptTokens: 100, completionTokens: 10)
    }

    private func text(_ s: String) -> ChatCompletion {
        ChatCompletion(content: s, finishReason: "stop", promptTokens: 150, completionTokens: 5)
    }

    /// 跑一轮：turn 决定权限（与 App 里同一个检查）；executed 记下真正执行了的工具。
    private func run(_ fake: FakeTransport, turn: AssistantTurnKind?, maxIterations: Int = 8, timeout: TimeInterval = 60,
                     now: @escaping () -> Date = Date.init,
                     executed: @escaping (String, [String: JSONValue]) -> MCPServerCore.ToolOutcome = { _, _ in .init(text: "ok") })
        -> (result: Result<AssistantToolLoop.Outcome, AssistantToolLoop.Failure>?, loop: AssistantToolLoop) {
        var result: Result<AssistantToolLoop.Outcome, AssistantToolLoop.Failure>?
        let loop = AssistantToolLoop(
            model: "m", prefix: [.system("sys")], user: .user("[UTTERANCE]\nhi"), tools: AssistantTools.all,
            maxIterations: maxIterations, timeout: timeout,
            gate: { AssistantToolPolicy.check($0, turn: turn) },
            transport: fake.transport,
            executor: { name, args, done in done(executed(name, args)) }, now: now)
        loop.start { result = $0 }
        return (result, loop)
    }

    func testToolCallThenFinalText() throws {
        let fake = FakeTransport([.success(call("list_sessions")), .success(text("有两个会话"))])
        var executed: [String] = []
        let (result, _) = run(fake, turn: .utterance) { name, _ in
            executed.append(name)
            return .init(text: "s1 poems working")
        }
        let outcome = try XCTUnwrap(result).get()
        XCTAssertEqual(outcome.text, "有两个会话", "only the text after the last tool call is spoken")
        XCTAssertEqual(executed, ["list_sessions"])
        XCTAssertEqual(outcome.requests, 2)
        XCTAssertEqual(outcome.toolCalls, 1)
        XCTAssertEqual(outcome.rejected, 0)
        XCTAssertEqual(outcome.promptTokens, 250)
        XCTAssertEqual(outcome.lastPromptTokens, 150)
        XCTAssertEqual(outcome.turnMessages.map(\.role), ["user", "assistant", "tool", "assistant"])
        XCTAssertEqual(outcome.turnMessages[1].content, "", "commentary before a tool call is dropped")
        let second = fake.messages(1)
        XCTAssertEqual(second.map { $0["role"]?.stringValue }, ["system", "user", "assistant", "tool"])
        XCTAssertEqual(second[3]["content"], "s1 poems working")
        XCTAssertEqual(second[3]["tool_call_id"], "c1")
    }

    func testNoToolReply() throws {
        let fake = FakeTransport([.success(text("<think>嗯</think>不客气"))])
        let outcome = try XCTUnwrap(run(fake, turn: .utterance).result).get()
        XCTAssertEqual(outcome.text, "不客气")
        XCTAssertEqual(outcome.turnMessages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(outcome.finishReason, "stop")
    }

    func testMutatingToolDuringEventIsRejectedWithoutRunning() throws {
        let fake = FakeTransport([.success(call("type_text", #"{"text":"rm -rf /","submit":true}"#)),
                                  .success(text("SILENT"))])
        var executed: [String] = []
        let (result, _) = run(fake, turn: .event) { name, _ in
            executed.append(name)
            return .init(text: "typed")
        }
        let outcome = try XCTUnwrap(result).get()
        XCTAssertEqual(executed, [], "type_text must not run for an [EVENT]")
        XCTAssertEqual(outcome.rejected, 1)
        let toolResult = fake.messages(1).last?["content"]?.stringValue ?? ""
        XCTAssertTrue(toolResult.hasPrefix("Error: type_text is not allowed"), toolResult)
        XCTAssertTrue(toolResult.contains("[EVENT]"))
    }

    func testPolicyMatrixMatchesTheMCPPath() throws {
        for turn in [AssistantTurnKind.utterance, .event, .consultResult, .summarize, nil] as [AssistantTurnKind?] {
            for spec in AssistantTools.all {
                let fake = FakeTransport([.success(call(spec.name)), .success(text("ok"))])
                var ran = false
                _ = run(fake, turn: turn) { _, _ in
                    ran = true
                    return .init(text: "ok")
                }
                XCTAssertEqual(ran, AssistantToolPolicy.isAllowed(spec.name, turn: turn), "\(spec.name) in \(String(describing: turn))")
                XCTAssertEqual(ran, AssistantToolPolicy.check(spec.name, turn: turn) == nil)
            }
        }
    }

    func testReadOnlyToolDuringSummarizeRuns() throws {
        let fake = FakeTransport([.success(call("read_transcript")), .success(text("它改了两个文件"))])
        var executed: [String] = []
        let (result, _) = run(fake, turn: .summarize) { name, _ in
            executed.append(name)
            return .init(text: "EDIT a.swift")
        }
        XCTAssertEqual(try XCTUnwrap(result).get().text, "它改了两个文件")
        XCTAssertEqual(executed, ["read_transcript"])
    }

    func testMalformedArgumentsAndUnknownToolGoBackToTheModel() throws {
        let both = ChatCompletion(content: nil, toolCalls: [
            ChatToolCall(id: "a", name: "type_text", arguments: "{\"text\": "),
            ChatToolCall(id: "b", name: "format_disk", arguments: "{}"),
            ChatToolCall(id: "c", name: "list_sessions", arguments: ""),
        ])
        let fake = FakeTransport([.success(both), .success(text("好了"))])
        var executed: [String] = []
        let (result, _) = run(fake, turn: .utterance) { name, _ in
            executed.append(name)
            return .init(text: "s1")
        }
        let outcome = try XCTUnwrap(result).get()
        XCTAssertEqual(executed, ["list_sessions"])
        XCTAssertEqual(outcome.rejected, 2)
        XCTAssertEqual(outcome.toolCalls, 3)
        let results = fake.messages(1).filter { $0["role"] == "tool" }
        XCTAssertEqual(results.map { $0["tool_call_id"]?.stringValue }, ["a", "b", "c"], "every call gets a result, in order")
        XCTAssertTrue(results[0]["content"]?.stringValue?.contains("not valid JSON") == true)
        XCTAssertTrue(results[1]["content"]?.stringValue?.contains("unknown tool format_disk") == true)
        XCTAssertEqual(results[2]["content"], "s1")
    }

    func testToolErrorsAreMarked() throws {
        let fake = FakeTransport([.success(call("read_screen")), .success(text("读不到"))])
        _ = run(fake, turn: .utterance) { _, _ in .init(text: "s3 runs in an external terminal", isError: true) }
        XCTAssertEqual(fake.messages(1).last?["content"], "Error: s3 runs in an external terminal")
    }

    func testIterationCapForcesTextThenFails() throws {
        let fake = FakeTransport(Array(repeating: .success(call("list_sessions")), count: 10))
        let (result, _) = run(fake, turn: .utterance, maxIterations: 3)
        XCTAssertEqual(result.map { r -> AssistantToolLoop.Failure? in if case .failure(let f) = r { return f }; return nil },
                       .tooManyIterations)
        XCTAssertEqual(fake.bodies.count, 4)
        XCTAssertEqual(fake.bodies.prefix(3).map { $0["tool_choice"] }, [nil, nil, nil])
        XCTAssertEqual(fake.bodies[3]["tool_choice"], "none")

        let recovering = FakeTransport([.success(call("list_sessions")), .success(text("好"))])
        XCTAssertEqual(try XCTUnwrap(run(recovering, turn: .utterance, maxIterations: 1).result).get().text, "好")
        XCTAssertEqual(recovering.bodies.count, 2)
        XCTAssertEqual(recovering.bodies[1]["tool_choice"], "none")
    }

    func testHTTPFailureAndTimeouts() throws {
        let failing = FakeTransport([.failure(.http(500, nil))])
        let (r1, _) = run(failing, turn: .utterance)
        guard case .failure(.api(.http(500, nil)))? = r1 else { return XCTFail("\(String(describing: r1))") }

        let slow = FakeTransport([.failure(.timeout)])
        guard case .failure(.timeout)? = run(slow, turn: .utterance).result else { return XCTFail() }

        // 总时长用完：工具执行花掉了全部时间后不再发请求。
        var clock = Date(timeIntervalSince1970: 1000)
        let fake = FakeTransport([.success(call("list_sessions")), .success(text("x"))])
        let (r3, _) = run(fake, turn: .utterance, timeout: 10, now: { clock }) { _, _ in
            clock = clock.addingTimeInterval(11)
            return .init(text: "ok")
        }
        guard case .failure(.timeout)? = r3 else { return XCTFail("\(String(describing: r3))") }
        XCTAssertEqual(fake.bodies.count, 1)
        XCTAssertEqual(fake.timeouts.first ?? 0, 10, accuracy: 0.001, "each request only gets the remaining time")
    }

    func testCancelStopsTheRequestAndNeverCompletes() {
        let fake = FakeTransport([])
        fake.hang = true
        let (result, loop) = run(fake, turn: .utterance)
        XCTAssertNil(result)
        loop.cancel()
        XCTAssertEqual(fake.cancelled, 1)
        loop.cancel()
        XCTAssertEqual(fake.cancelled, 1)
    }

    func testExecutorAnsweringTwiceIsIgnored() throws {
        let fake = FakeTransport([.success(call("list_sessions")), .success(text("好"))])
        var result: Result<AssistantToolLoop.Outcome, AssistantToolLoop.Failure>?
        let loop = AssistantToolLoop(model: "m", prefix: [], user: .user("x"), tools: AssistantTools.all, timeout: 60,
                                     gate: { _ in nil }, transport: fake.transport,
                                     executor: { _, _, done in
                                         done(.init(text: "one"))
                                         done(.init(text: "two"))
                                     })
        loop.start { result = $0 }
        XCTAssertEqual(try XCTUnwrap(result).get().turnMessages.filter { $0.role == "tool" }.count, 1)
        XCTAssertEqual(fake.bodies.count, 2)
    }

    func testLongToolResultsAreClipped() throws {
        let fake = FakeTransport([.success(call("read_screen")), .success(text("好"))])
        let (result, _) = run(fake, turn: .utterance) { _, _ in .init(text: String(repeating: "x", count: 50_000)) }
        let tool = try XCTUnwrap(try XCTUnwrap(result).get().turnMessages.first { $0.role == "tool" })
        XCTAssertLessThan(tool.content?.count ?? 0, AssistantToolLoop.toolResultLimit + 50)
        XCTAssertTrue(tool.content?.hasSuffix("(truncated)") == true)
    }

    /// 真正的计时器：请求挂起、或工具一直不返回时，到点就以超时结束（不靠下一次请求时才检查）。
    func testDeadlineTimerFiresWhileARequestOrAToolHangs() throws {
        var timers: [(TimeInterval, () -> Void)] = []
        let hanging = FakeTransport([])
        hanging.hang = true
        var r1: Result<AssistantToolLoop.Outcome, AssistantToolLoop.Failure>?
        let loop1 = AssistantToolLoop(model: "m", prefix: [], user: .user("x"), tools: AssistantTools.all, timeout: 30,
                                      gate: { _ in nil }, transport: hanging.transport, executor: { _, _, _ in },
                                      schedule: { timers.append(($0, $1)) })
        loop1.start { r1 = $0 }
        XCTAssertNil(r1)
        XCTAssertEqual(timers.map(\.0), [30])
        timers[0].1()
        guard case .failure(.timeout)? = r1 else { return XCTFail("\(String(describing: r1))") }
        XCTAssertEqual(hanging.cancelled, 1, "the hanging request is cancelled")

        timers = []
        let fake = FakeTransport([.success(call("list_sessions"))])
        var r2: Result<AssistantToolLoop.Outcome, AssistantToolLoop.Failure>?
        var late: ((MCPServerCore.ToolOutcome) -> Void)?
        let loop2 = AssistantToolLoop(model: "m", prefix: [], user: .user("x"), tools: AssistantTools.all, timeout: 5,
                                      gate: { _ in nil }, transport: fake.transport,
                                      executor: { _, _, done in late = done },  // 工具卡住
                                      schedule: { timers.append(($0, $1)) })
        loop2.start { r2 = $0 }
        XCTAssertNil(r2)
        timers[0].1()
        guard case .failure(.timeout)? = r2 else { return XCTFail("\(String(describing: r2))") }
        late?(.init(text: "too late"))
        XCTAssertEqual(fake.bodies.count, 1, "a late tool result starts no new request")
        timers[0].1()  // 再触发一次也不会再回调
    }
}
