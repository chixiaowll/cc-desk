import XCTest
@testable import CCDeskCore

final class AgentResolverTests: XCTestCase {
    func testResolvesCodexBySessionFileAndPiByTTYHook() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codexRoot = root.appendingPathComponent("codex"), piRoot = root.appendingPathComponent("pi")
        let now = Date()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let day = codexRoot.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let ts = ISO8601DateFormatter().string(from: now)
        try Data(#"{"type":"session_meta","payload":{"id":"cx-1","cwd":"/w/c","timestamp":"\#(ts)"}}"#.utf8)
            .write(to: day.appendingPathComponent("rollout-x-cx-1.jsonl"))

        let table = ProcessTable(byPID: [
            10: ProcInfo(pid: 10, ppid: 1, tty: "ttys001", command: "/x/bin/codex", args: "/x/bin/codex"),
            20: ProcInfo(pid: 20, ppid: 1, tty: "ttys002", command: "pi", args: "pi"),
            30: ProcInfo(pid: 30, ppid: 1, tty: "ttys003", command: "-zsh", args: "-zsh"),
        ])
        let start = now.addingTimeInterval(-60)
        let hooks = HookStates([
            HookState(agent: .codex, sessionID: "cx-1", tty: nil, pid: nil, cwd: "/w/c", status: .working, updatedAt: now),
            HookState(agent: .pi, sessionID: "pi-1", tty: "ttys002", pid: 20, cwd: "/w/p", status: .idle, updatedAt: now),
        ])
        let index = AgentSessionIndex(codexRoot: codexRoot, piRoot: piRoot)
        let snaps = AgentResolver.resolve(processes: table, details: { pid in
            (pid == 10 ? "/w/c" : "/w/p", start)
        }, hooks: hooks, index: index, now: now)
        XCTAssertEqual(snaps.map(\.pid), [10, 20])
        XCTAssertEqual(snaps[0].kind, .codex)
        XCTAssertEqual(snaps[0].sessionID, "cx-1")
        XCTAssertNotNil(snaps[0].sessionPath)
        XCTAssertEqual(snaps[0].hook?.status, .working)
        XCTAssertEqual(snaps[1].kind, .pi)
        XCTAssertEqual(snaps[1].sessionID, "pi-1", "pi reports its id via the hook before the session file exists")
        XCTAssertNil(snaps[1].sessionPath)
        XCTAssertEqual(snaps[1].hook?.status, .idle)
    }

    func testFallbackSessionUsedOnlyWhenNothingElseKnown() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let index = AgentSessionIndex(codexRoot: root.appendingPathComponent("c"), piRoot: root.appendingPathComponent("p"))
        let table = ProcessTable(byPID: [
            20: ProcInfo(pid: 20, ppid: 1, tty: "ttys002", command: "pi", args: "pi"),
            21: ProcInfo(pid: 21, ppid: 1, tty: "ttys003", command: "pi", args: "pi"),
        ])
        let hooks = HookStates([
            HookState(agent: .pi, sessionID: "from-hook", tty: "ttys003", pid: 21, cwd: nil, status: .idle, updatedAt: Date()),
        ])
        let snaps = AgentResolver.resolve(processes: table, details: { _ in ("/w", Date().addingTimeInterval(-5)) },
                                          hooks: hooks, index: index,
                                          fallbackSessions: ["ttys002": (.pi, "restored"), "ttys003": (.pi, "stale")])
        XCTAssertEqual(snaps.map(\.sessionID), ["restored", "from-hook"])
        let wrongKind = AgentResolver.resolve(processes: table, details: { _ in ("/w", nil) }, hooks: HookStates(),
                                              index: index, fallbackSessions: ["ttys002": (.codex, "x")])
        XCTAssertNil(wrongKind.first?.sessionID)
    }

    func testStatusFallsBackToUnknownAtProcessStart() {
        let start = Date(timeIntervalSince1970: 50)
        let s = AgentResolver.status(hook: nil, screen: nil, startedAt: start, now: Date())
        XCTAssertEqual(s, StatusObservation(status: .unknown, at: start))
        let hook = HookState(agent: .pi, sessionID: nil, tty: "t", pid: 1, cwd: nil, status: .working,
                             updatedAt: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(AgentResolver.status(hook: hook, screen: nil, startedAt: start, now: Date()).status, .working)
    }

    /// 重启 CC Desk 后屏幕规则重新识别出「空闲」：从会话文件最后写入的时间算起，而不是从识别的那一刻。
    func testIdleSinceLastSessionFileWrite() {
        let now = Date()
        let lastWrite = now.addingTimeInterval(-3 * 86400)
        let screenIdle = StatusObservation(status: .idle, at: now.addingTimeInterval(-30))
        let idle = AgentResolver.status(hook: nil, screen: screenIdle, startedAt: nil, now: now, lastActivity: lastWrite)
        XCTAssertEqual(idle, StatusObservation(status: .idle, at: lastWrite))
        // 处理中不改时间；文件比状态还新（正在写）时也不改。
        let screenWorking = StatusObservation(status: .working, at: now.addingTimeInterval(-30))
        XCTAssertEqual(AgentResolver.status(hook: nil, screen: screenWorking, startedAt: nil, now: now, lastActivity: lastWrite),
                       screenWorking)
        XCTAssertEqual(AgentResolver.status(hook: nil, screen: screenIdle, startedAt: nil, now: now, lastActivity: now),
                       screenIdle)
    }
}
