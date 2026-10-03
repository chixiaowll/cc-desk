import XCTest
@testable import CCDeskCore

final class AgentTranscriptsTests: XCTestCase {
    // MARK: 合成样本（结构取自 codex-cli 0.160.0 / pi 0.73.1 的真实文件，内容为虚构）

    let codexLines = [
        #"{"timestamp":"2026-10-03T04:50:03.858Z","type":"session_meta","payload":{"session_id":"01a1-codex","id":"01a1-codex","timestamp":"2026-10-03T04:49:30.000Z","cwd":"/w/proj","cli_version":"0.160.0","source":"vscode","originator":"codex-tui"}}"#,
        #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<skills_instructions>…"}]}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/w/proj</cwd>"}]}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"修复登录页的样式问题"}]}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"好的"}]}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"再跑一下测试"}]}}"#,
        #"{"type":"event_msg","payload":{"type":"task_complete"}}"#,
    ]

    let piLines = [
        #"{"type":"session","version":3,"id":"01a1-pi","timestamp":"2026-10-03T04:42:09.171Z","cwd":"/w/pi"}"#,
        #"{"type":"model_change","id":"4d4f","parentId":null,"provider":"openrouter","modelId":"m"}"#,
        #"{"type":"message","id":"e635","message":{"role":"user","content":[{"type":"text","text":"写一个 hello.py"}],"timestamp":1}}"#,
        #"{"type":"message","id":"c5b3","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}"#,
        #"{"type":"message","id":"c5b4","message":{"role":"user","content":"再改成中文"}}"#,
        #"{"type":"session_info","id":"x1","name":"  hello 脚本  "}"#,
    ]

    func data(_ lines: [String]) -> Data { Data(lines.joined(separator: "\n").utf8) }

    func testCodexHeader() {
        let h = AgentTranscriptReader.header(kind: .codex, head: data(codexLines))
        XCTAssertEqual(h?.sessionID, "01a1-codex")
        XCTAssertEqual(h?.cwd, "/w/proj")
        XCTAssertEqual(h?.startedAt, AgentTranscriptReader.parseISODate("2026-10-03T04:49:30.000Z"))
        XCTAssertNotNil(h?.startedAt)
    }

    func testCodexHeaderFallsBackToIdField() {
        let line = #"{"type":"session_meta","payload":{"id":"only-id","cwd":"/a"}}"#
        XCTAssertEqual(AgentTranscriptReader.header(kind: .codex, head: data([line]))?.sessionID, "only-id")
        XCTAssertNil(AgentTranscriptReader.header(kind: .codex, head: data([#"{"type":"session_meta","payload":{"id":"x"}}"#])))
        XCTAssertNil(AgentTranscriptReader.header(kind: .codex, head: data(piLines)))
    }

    func testCodexMetaSkipsInjectedBlocks() {
        let meta = AgentTranscriptReader.meta(kind: .codex, head: data(codexLines), tail: data(codexLines))
        XCTAssertEqual(meta.firstPrompt, "修复登录页的样式问题")
        XCTAssertEqual(meta.lastPrompt, "再跑一下测试")
        XCTAssertNil(meta.customTitle)
        XCTAssertEqual(meta.displayTitle(fallbackName: nil, fallbackIsDerived: true), "修复登录页的样式问题")
    }

    func testCodexLegacyUserMessageEvent() {
        let line = #"{"type":"event_msg","payload":{"type":"user_message","message":"legacy prompt"}}"#
        let meta = AgentTranscriptReader.meta(kind: .codex, head: data([line]), tail: data([line]))
        XCTAssertEqual(meta.firstPrompt, "legacy prompt")
    }

    func testPiHeaderAndMeta() {
        let h = AgentTranscriptReader.header(kind: .pi, head: data(piLines))
        XCTAssertEqual(h, AgentSessionHeader(sessionID: "01a1-pi", cwd: "/w/pi",
                                             startedAt: AgentTranscriptReader.parseISODate("2026-10-03T04:42:09.171Z")))
        let meta = AgentTranscriptReader.meta(kind: .pi, head: data(piLines), tail: data(piLines))
        XCTAssertEqual(meta.firstPrompt, "写一个 hello.py")
        XCTAssertEqual(meta.lastPrompt, "再改成中文")
        XCTAssertEqual(meta.customTitle, "hello 脚本")
        XCTAssertEqual(meta.displayTitle(fallbackName: nil, fallbackIsDerived: true), "hello 脚本")
    }

    func testTruncatedTailFirstLineIsIgnored() {
        var tail = data(piLines)
        tail = tail.dropFirst(10)
        let meta = AgentTranscriptReader.meta(kind: .pi, head: Data(), tail: Data(tail))
        XCTAssertEqual(meta.lastPrompt, "再改成中文")
        XCTAssertNil(meta.firstPrompt)
    }

    func testPiDirectoryName() {
        XCTAssertEqual(AgentSessionIndex.piDirectoryName(cwd: "/private/tmp/claude-501/-Users-x/pi-test"),
                       "--private-tmp-claude-501--Users-x-pi-test--")
        XCTAssertEqual(AgentSessionIndex.piDirectoryName(cwd: "/a:b"), "--a-b--")
    }

    // MARK: 配对

    func file(_ sid: String, kind: AgentKind = .codex, cwd: String = "/w", created: TimeInterval?, modified: TimeInterval) -> AgentSessionFile {
        AgentSessionFile(kind: kind, sessionID: sid, cwd: cwd, path: "/s/\(sid).jsonl",
                         createdAt: created.map { Date(timeIntervalSince1970: $0) },
                         modifiedAt: Date(timeIntervalSince1970: modified))
    }

    func proc(_ pid: Int32, kind: AgentKind = .codex, cwd: String? = "/w", start: TimeInterval, hint: String? = nil) -> AgentProcessCandidate {
        AgentProcessCandidate(pid: pid, kind: kind, cwd: cwd, startedAt: Date(timeIntervalSince1970: start), sessionHint: hint)
    }

    func testMatchesNewSessionCreatedAfterStart() {
        let m = AgentSessionMatcher.match(processes: [proc(1, start: 100)],
                                          files: [file("old", created: 10, modified: 50), file("new", created: 120, modified: 130)])
        XCTAssertEqual(m[1]?.sessionID, "new")
    }

    func testIgnoresFilesFromOtherCwdKindOrBeforeStart() {
        let m = AgentSessionMatcher.match(processes: [proc(1, start: 100)],
                                          files: [file("a", cwd: "/other", created: 120, modified: 130),
                                                  file("b", kind: .pi, created: 120, modified: 130),
                                                  file("c", created: 10, modified: 50)])
        XCTAssertNil(m[1])
    }

    func testResumedSessionMatchedByRecentWrite() {
        let m = AgentSessionMatcher.match(processes: [proc(1, start: 100)],
                                          files: [file("resumed", created: 10, modified: 150)])
        XCTAssertEqual(m[1]?.sessionID, "resumed")
    }

    func testHintWins() {
        let m = AgentSessionMatcher.match(processes: [proc(1, start: 100, hint: "01a1-wanted")],
                                          files: [file("01a1-wanted-full", created: 10, modified: 20),
                                                  file("newer", created: 120, modified: 130)])
        XCTAssertEqual(m[1]?.sessionID, "01a1-wanted-full")
        let byPath = AgentSessionMatcher.match(processes: [proc(2, kind: .pi, start: 100, hint: "/s/p.jsonl")],
                                               files: [file("p", kind: .pi, created: 1, modified: 2)])
        XCTAssertEqual(byPath[2]?.sessionID, "p")
    }

    func testTwoProcessesSameCwdGetDistinctFiles() {
        let m = AgentSessionMatcher.match(processes: [proc(1, start: 100), proc(2, start: 200)],
                                          files: [file("a", created: 150, modified: 160), file("b", created: 250, modified: 260)])
        XCTAssertEqual(m[1]?.sessionID, "a")
        XCTAssertEqual(m[2]?.sessionID, "b")
    }

    // MARK: 索引（临时目录）

    func testIndexMatchesAndListsHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codexRoot = root.appendingPathComponent("codex")
        let piRoot = root.appendingPathComponent("pi")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let c = cal.dateComponents([.year, .month, .day], from: now)
        let dayDir = codexRoot.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let codexFile = dayDir.appendingPathComponent("rollout-x-01a1-codex.jsonl")
        try data(codexLines.map { $0.replacingOccurrences(of: "2026-10-03T04:49:30.000Z", with: "2026-09-21T14:00:00.000Z") })
            .write(to: codexFile)
        let piDir = piRoot.appendingPathComponent(AgentSessionIndex.piDirectoryName(cwd: "/w/pi"))
        try FileManager.default.createDirectory(at: piDir, withIntermediateDirectories: true)
        try data(piLines).write(to: piDir.appendingPathComponent("2026_01a1-pi.jsonl"))

        let index = AgentSessionIndex(codexRoot: codexRoot, piRoot: piRoot, calendar: cal)
        let matched = index.match(processes: [
            AgentProcessCandidate(pid: 1, kind: .codex, cwd: "/w/proj", startedAt: now.addingTimeInterval(-3600), sessionHint: nil),
            AgentProcessCandidate(pid: 2, kind: .pi, cwd: "/w/pi", startedAt: now.addingTimeInterval(-3600), sessionHint: nil),
        ], now: now)
        // 文件刚写入（mtime ≈ 真实当前时间，晚于 start），两者都能配上。
        XCTAssertEqual(matched[1]?.sessionID, "01a1-codex")
        XCTAssertEqual(matched[2]?.sessionID, "01a1-pi")
        XCTAssertEqual(index.locate(kind: .codex, sessionID: "01a1-codex").map(ProjectResolver.canonical),
                       ProjectResolver.canonical(codexFile.path))

        let history = index.history(excluding: ["01a1-pi"])
        XCTAssertEqual(history.map(\.sessionID), ["01a1-codex"])
        XCTAssertEqual(history.first?.kind, .codex)
        XCTAssertEqual(history.first?.title, "修复登录页的样式问题")
        XCTAssertEqual(history.first?.cwd, "/w/proj")
        XCTAssertEqual(index.history(excluding: []).count, 2)
    }
}
