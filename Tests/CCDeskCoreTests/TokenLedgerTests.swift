import XCTest
@testable import CCDeskCore

final class TokenLedgerTests: ZhHansTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("token-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var roots: TokenLedger.Roots {
        TokenLedger.Roots(claude: root.appendingPathComponent("claude"), codex: root.appendingPathComponent("codex"),
                          pi: root.appendingPathComponent("pi"))
    }

    private func write(_ path: String, _ lines: [String], append: Bool = false) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.map { $0 + "\n" }.joined()
        if append, let h = FileHandle(forWritingAtPath: url.path) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            h.closeFile()
        } else {
            try Data(text.utf8).write(to: url)
        }
    }

    private func claude(id: String, out: Int, ts: String = "2026-10-06T08:00:00.000Z", model: String = "claude-opus-5-5",
                        cwd: String = "/p/app") -> String {
        #"{"type":"assistant","cwd":"\#(cwd)","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"\#(model)","content":[],"usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":\#(out)}}}"#
    }

    private let now = AgentTranscriptReader.parseISODate("2026-10-06T12:00:00Z")!

    // MARK: 解析

    func testClaudeUsageNormalized() {
        var p = TokenUsageParser(kind: .claude)
        let r = p.consume(Data(claude(id: "m1", out: 50).utf8))
        XCTAssertEqual(r?.usage, TokenUsage(input: 2, output: 50, cacheRead: 1000, cacheWrite: 100))
        XCTAssertEqual(r?.key, "claude:m1")
        XCTAssertEqual(r?.model, "claude-opus-5-5")
        // 不含用量的行（工具结果等）直接跳过。
        XCTAssertNil(p.consume(Data(#"{"type":"user","message":{"content":"hi"}}"#.utf8)))
    }

    func testCodexUsesCumulativeDeltasAndTurnModel() {
        var p = TokenUsageParser(kind: .codex)
        XCTAssertNil(p.consume(Data(#"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#.utf8)))
        func tc(_ input: Int, _ cached: Int, _ out: Int) -> Data {
            Data(#"{"timestamp":"2026-10-06T08:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(out)},"last_token_usage":{"input_tokens":900,"output_tokens":100},"model_context_window":10000}}}"#.utf8)
        }
        let first = p.consume(tc(1000, 200, 50))
        XCTAssertEqual(first?.usage, TokenUsage(input: 800, output: 50, cacheRead: 200))
        XCTAssertEqual(first?.model, "gpt-5.5")
        // 同一累计值重复上报：没有增量。
        XCTAssertNil(p.consume(tc(1000, 200, 50)))
        XCTAssertEqual(p.consume(tc(3000, 1200, 80))?.usage, TokenUsage(input: 1000, output: 30, cacheRead: 1000))
        XCTAssertEqual(p.contextUsed, 1000)
        XCTAssertEqual(p.contextWindow, 10000)
        XCTAssertNil(p.consume(Data(#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#.utf8)))
    }

    func testPiUsage() {
        var p = TokenUsageParser(kind: .pi)
        let line = #"{"type":"message","id":"a1","timestamp":"2026-10-06T08:00:00.000Z","message":{"role":"assistant","model":"qwen","usage":{"input":10,"output":5,"cacheRead":3,"cacheWrite":0,"totalTokens":18}}}"#
        let r = p.consume(Data(line.utf8))
        XCTAssertEqual(r?.usage, TokenUsage(input: 10, output: 5, cacheRead: 3))
        XCTAssertEqual(r?.key, "pi:a1")
    }

    func testQuickISODateMatchesFormatter() {
        for s in ["2026-10-06T08:00:00Z", "2026-02-28T23:59:59.123Z", "2024-02-29T12:00:00.5Z", "1999-01-01T00:00:00.000Z"] {
            let quick = TokenUsageParser.quickISODate(s)
            let slow = AgentTranscriptReader.parseISODate(s)
            XCTAssertNotNil(quick, s)
            XCTAssertEqual(quick?.timeIntervalSince1970 ?? 0, slow?.timeIntervalSince1970 ?? -1, accuracy: 0.001, s)
        }
        XCTAssertNil(TokenUsageParser.quickISODate("2026-10-06T08:00:00+08:00"))
        XCTAssertNil(TokenUsageParser.quickISODate("nope"))
    }

    func testCompactFormatting() {
        XCTAssertEqual(TokenUsage.compact(950), "950")
        XCTAssertEqual(TokenUsage.compact(12_340), "12.3K")
        XCTAssertEqual(TokenUsage.compact(4_560_000), "4.56M")
        XCTAssertEqual(TokenUsage.compact(120_000_000), "120M")
        XCTAssertEqual(TokenUsage.compact(2_000), "2K")
    }

    // MARK: 账本

    func testSessionTotalsDedupeMessageIDsAndIncludeSubagents() throws {
        let sid = "11111111-1111-1111-1111-111111111111"
        try write("claude/-p-app/\(sid).jsonl", [
            claude(id: "m1", out: 10), claude(id: "m1", out: 10), // 同一回复分两行写入
            #"{"type":"user","cwd":"/p/app","message":{"content":"x"}}"#,
            claude(id: "m2", out: 20),
        ])
        try write("claude/-p-app/\(sid)/subagents/agent-a.jsonl", [claude(id: "s1", out: 5)])
        let ledger = TokenLedger(roots: roots)
        ledger.refresh(now: now)
        let s = ledger.session(kind: .claude, sessionID: sid)
        XCTAssertEqual(s?.replies, 3)
        XCTAssertEqual(s?.usage.output, 35)
        XCTAssertNil(ledger.session(kind: .claude, sessionID: "other"))
    }

    func testIncrementalReadKeepsPartialLineForLater() throws {
        let sid = "22222222-2222-2222-2222-222222222222"
        let path = "claude/-p-app/\(sid).jsonl"
        try write(path, [claude(id: "m1", out: 10)])
        let ledger = TokenLedger(roots: roots)
        ledger.refresh(now: now)
        // 追加一行完整的和半行。
        let url = root.appendingPathComponent(path)
        let h = try XCTUnwrap(FileHandle(forWritingAtPath: url.path))
        h.seekToEndOfFile()
        let half = claude(id: "m3", out: 7)
        h.write(Data((claude(id: "m2", out: 20) + "\n" + half.prefix(40)).utf8))
        ledger.refresh(now: now)
        XCTAssertEqual(ledger.session(kind: .claude, sessionID: sid)?.usage.output, 30)
        h.write(Data((half.dropFirst(40) + "\n").utf8))
        h.closeFile()
        ledger.refresh(now: now)
        XCTAssertEqual(ledger.session(kind: .claude, sessionID: sid)?.usage.output, 37)
    }

    func testSummaryWindowProjectsModelsAndCrossFileDedupe() throws {
        try write("claude/-p-app/aaaaaaaa-0000-0000-0000-000000000001.jsonl", [
            claude(id: "m1", out: 10, ts: "2026-10-06T09:00:00Z"),
            claude(id: "old", out: 1000, ts: "2026-09-01T09:00:00Z"),
        ])
        // 续接会话把 m1 重放进新文件：只算一次。
        try write("claude/-p-app/aaaaaaaa-0000-0000-0000-000000000002.jsonl", [
            claude(id: "m1", out: 10, ts: "2026-10-06T09:00:00Z"),
            claude(id: "m2", out: 20, ts: "2026-10-05T09:00:00Z", model: "claude-sonnet-5"),
        ])
        try write("pi/--p-web--/2026-10-06T06-01-30-000Z_bbbbbbbb-0000-0000-0000-000000000001.jsonl", [
            #"{"type":"session","id":"bbbbbbbb-0000-0000-0000-000000000001","cwd":"/p/web","timestamp":"2026-10-06T06:00:00Z"}"#,
            #"{"type":"message","id":"x","timestamp":"2026-10-06T08:00:00.000Z","message":{"role":"assistant","model":"qwen","usage":{"input":5,"output":5,"cacheRead":0,"cacheWrite":0}}}"#,
        ])
        let ledger = TokenLedger(roots: roots)
        ledger.refresh(now: now)
        let week = ledger.summary(since: now.addingTimeInterval(-7 * 86400)) { $0.map { ($0 as NSString).lastPathComponent } ?? "?" }
        XCTAssertEqual(week.total.output, 35)
        XCTAssertEqual(week.byProject.map(\.name), ["app", "web"])
        XCTAssertEqual(week.byAgent.map(\.name), ["Claude", "pi"])
        XCTAssertEqual(week.byModel.first?.name, "claude-sonnet-5")
        let today = ledger.summary(since: AgentTranscriptReader.parseISODate("2026-10-06T00:00:00Z")!) { _ in "x" }
        XCTAssertEqual(today.total.output, 15)
    }

    func testOldFilesAreSkippedAndCodexSessionIDFromName() throws {
        let path = "codex/2026/09/01/rollout-2026-09-01T10-00-00-cccccccc-0000-0000-0000-000000000001.jsonl"
        try write(path, [#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":1}}}}"#])
        let url = root.appendingPathComponent(path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86400)], ofItemAtPath: url.path)
        let ledger = TokenLedger(roots: roots)
        ledger.refresh(now: now)
        XCTAssertNil(ledger.session(kind: .codex, sessionID: "cccccccc-0000-0000-0000-000000000001"))
        XCTAssertEqual(TokenLedger.sessionID(kind: .codex, url: url), "cccccccc-0000-0000-0000-000000000001")
    }

    func testTooltipText() {
        let s = SessionTokenSummary(usage: TokenUsage(input: 2_000, output: 30_000, cacheRead: 950_000, cacheWrite: 18_000),
                                    replies: 4, contextUsed: 62, contextWindow: 100)
        XCTAssertEqual(s.tooltipText, "Token 1M（输入 2K · 输出 30K · 缓存读 950K · 缓存写 18K）\n缓存命中 98% · 上下文已用 62%")
        XCTAssertEqual(SessionTokenSummary(usage: TokenUsage(output: 5), replies: 1).tooltipText, "Token 5（输出 5）")
    }
}
