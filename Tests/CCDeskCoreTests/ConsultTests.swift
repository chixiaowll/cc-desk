import XCTest
@testable import CCDeskCore

final class ConsultTests: XCTestCase {
    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func testCommandIsReadOnlyAndNeverPrompts() {
        let args = ConsultCommand.arguments(level: nil, profile: nil, language: "zh-Hans")
        XCTAssertEqual(args.first, "-p")
        XCTAssertEqual(value(after: "--model", in: args), "sonnet", "default level is sonnet")
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertTrue(args.contains("--restricted"), "skip user settings (hooks, allow rules)")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertFalse(args.contains("--mcp-config"), "no MCP servers at all")
        XCTAssertEqual(value(after: "--permission-prompts", in: args), "none")
        XCTAssertEqual(value(after: "--output-format", in: args), "stream-json")
        XCTAssertEqual(value(after: "--tools", in: args), "Read,Grep,Glob,Bash")
        XCTAssertEqual(value(after: "--allowedTools", in: args),
                       "Read,Grep,Glob,Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*)")
        XCTAssertEqual(value(after: "--disallowedTools", in: args),
                       "Bash(*--output*),Bash(*--ext-diff*),Bash(*--textconv*),Bash(*--no-index*)")
        for forbidden in ["Edit", "Write", "NotebookEdit", "WebFetch", "--dangerously-skip-permissions", "bypassPermissions"] {
            XCTAssertFalse(args.contains { $0.split(separator: ",").contains(Substring(forbidden)) || $0 == forbidden },
                           "\(forbidden) must not be granted")
        }
        // 问题走 stdin：最后一个参数是系统提示词（不是位置参数的问题）。
        XCTAssertEqual(args[args.count - 2], "--append-system-prompt")
        XCTAssertTrue(args.last?.contains("结论：") == true)
    }

    func testOpusOnlyWhenRequested() {
        XCTAssertEqual(value(after: "--model", in: ConsultCommand.arguments(level: .opus, profile: nil, language: "en")), "opus")
        XCTAssertEqual(ConsultLevel(loose: "Opus 4"), .opus)
        XCTAssertEqual(ConsultLevel(loose: "SONNET"), .sonnet)
        XCTAssertNil(ConsultLevel(loose: "haiku"))
        XCTAssertNil(ConsultLevel(loose: nil))
    }

    func testProfileNarrowsToolsAndSuppliesModel() {
        let reviewer = AgentProfile(name: "reviewer", title: "审查员", description: "d", model: "opus",
                                    tools: ["Read", "Grep", "Bash(git diff:*)"], prompt: "Review carefully.",
                                    fileName: "reviewer.md")
        let args = ConsultCommand.arguments(level: nil, profile: reviewer, language: "en")
        XCTAssertEqual(value(after: "--model", in: args), "opus", "profile model when the level is not given")
        XCTAssertEqual(value(after: "--tools", in: args), "Read,Grep,Bash")
        XCTAssertEqual(value(after: "--allowedTools", in: args), "Read,Grep,Bash(git diff:*)")
        XCTAssertTrue(args.last?.contains("Review carefully.") == true)
        XCTAssertEqual(value(after: "--model", in: ConsultCommand.arguments(level: .sonnet, profile: reviewer, language: "en")),
                       "sonnet", "an explicit level wins")

        let readOnlyNoGit = AgentProfile(name: "r", description: "", model: nil, tools: ["Read", "Glob"], prompt: "p",
                                         fileName: "r.md")
        let a2 = ConsultCommand.arguments(level: nil, profile: readOnlyNoGit, language: "en")
        XCTAssertEqual(value(after: "--tools", in: a2), "Read,Glob", "no Bash when the profile has no git rules")
        XCTAssertEqual(value(after: "--model", in: a2), "sonnet")
    }

    func testParsesResultLineAndProgress() throws {
        let line = """
        {"type":"result","subtype":"success","is_error":false,"duration_ms":23310,"num_turns":9,"result":"结论：加法写成了减法。\\n\\n详情…",\
        "usage":{"input_tokens":10,"cache_read_input_tokens":64766,"cache_creation_input_tokens":5114,"output_tokens":1930},\
        "permission_denials":[{"tool_name":"Bash"},{"tool_name":"Bash"}]}
        """
        let o = try XCTUnwrap(ConsultOutcome.parse(line: line))
        XCTAssertEqual(o.inputTokens, 69890)
        XCTAssertEqual(o.outputTokens, 1930)
        XCTAssertEqual(o.durationMS, 23310)
        XCTAssertEqual(o.turns, 9)
        XCTAssertEqual(o.denials, 2)
        XCTAssertFalse(o.isError)
        XCTAssertEqual(ConsultAnswer.conclusion(o.answer), "加法写成了减法。")
        XCTAssertEqual(ConsultAnswer.details(o.answer), "详情…")

        XCTAssertNil(ConsultOutcome.parse(line: #"{"type":"assistant"}"#))
        let failed = try XCTUnwrap(ConsultOutcome.parse(line: #"{"type":"result","subtype":"error_max_turns","is_error":false}"#))
        XCTAssertTrue(failed.isError)

        let assistant = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"},"# +
            #"{"type":"text","text":"x"},{"type":"tool_use","name":"Grep"}]}}"#
        XCTAssertEqual(ConsultOutcome.toolCalls(line: assistant), 2)
        XCTAssertEqual(ConsultOutcome.toolCalls(line: #"{"type":"user","message":{"content":[{"type":"tool_result"}]}}"#), 0)
    }

    func testConclusionFallsBackToFirstLine() {
        XCTAssertEqual(ConsultAnswer.conclusion("## Summary\nIt is fine."), "Summary")
        XCTAssertEqual(ConsultAnswer.conclusion("Conclusion: Looks fine.\n\nMore."), "Looks fine.")
        XCTAssertEqual(ConsultAnswer.conclusion("**结论**：可以合并。"), "可以合并。")
        XCTAssertEqual(ConsultAnswer.details("No marker\nline 2"), "No marker\nline 2")
    }

    func testQuestionIncludesProject() {
        let q = ConsultPrompt.question("  为什么测试失败？ ", project: "/tmp/poems")
        XCTAssertEqual(q, "Question: 为什么测试失败？\nProject directory (your working directory): /tmp/poems")
    }

    // MARK: 任务簿

    func testBookLimitsConcurrencyAndAssignsIDs() throws {
        var book = ConsultBook()
        let t = Date(timeIntervalSince1970: 1000)
        let c1 = try book.start(question: "a", model: "sonnet", profile: nil, project: "/p", now: t).get()
        let c2 = try book.start(question: "b", model: "opus", profile: nil, project: "/p", now: t).get()
        XCTAssertEqual([c1.id, c2.id], ["c1", "c2"])
        XCTAssertEqual(book.start(question: "c", model: "sonnet", profile: nil, project: "/p", now: t),
                       .failure(.tooMany(running: ["c2", "c1"])))

        let outcome = ConsultOutcome(answer: "结论：好。", inputTokens: 100, outputTokens: 20, durationMS: 1000)
        let done = try XCTUnwrap(book.finish("c1", state: .done, outcome: outcome, now: t.addingTimeInterval(42)))
        XCTAssertEqual(done.duration, 42)
        XCTAssertNil(book.finish("c1", state: .cancelled, now: t), "already finished")
        let c3 = try book.start(question: "c", model: "sonnet", profile: nil, project: "/p", now: t).get()
        XCTAssertEqual(c3.id, "c3", "ids are never reused")
        XCTAssertEqual(book.jobs.map(\.id), ["c3", "c2", "c1"])
        XCTAssertEqual(book.job("C2")?.question, "b")
        XCTAssertEqual(book.job("c1")?.json["conclusion"], "好。")
    }

    func testBookCancelProgressAndRestartRecovery() throws {
        var book = ConsultBook()
        let t = Date()
        _ = try book.start(question: "a", model: "sonnet", profile: nil, project: "/p", now: t).get()
        book.progress("c1", toolCalls: 3)
        XCTAssertEqual(book.job("c1")?.toolCalls, 3)
        let data = try JSONEncoder().encode(book)
        var restored = try JSONDecoder().decode(ConsultBook.self, from: data)
        restored.recoverAfterRestart(now: t)
        XCTAssertEqual(restored.job("c1")?.state, .failed)
        XCTAssertEqual(try restored.start(question: "b", model: "sonnet", profile: nil, project: "/p", now: t).get().id, "c2",
                       "the id counter survives a restart")
    }

    func testBookKeepsRecentJobsOnly() throws {
        var book = ConsultBook()
        let t = Date()
        for i in 0..<(ConsultBook.keep + 5) {
            let job = try book.start(question: "\(i)", model: "sonnet", profile: nil, project: "/p", now: t).get()
            book.finish(job.id, state: .done, outcome: ConsultOutcome(answer: "x"), now: t)
        }
        XCTAssertEqual(book.jobs.count, ConsultBook.keep)
        XCTAssertEqual(book.jobs.first?.question, "\(ConsultBook.keep + 4)")
    }
}
