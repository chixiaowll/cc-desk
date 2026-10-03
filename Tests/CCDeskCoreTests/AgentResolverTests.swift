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

    func testStatusFallsBackToUnknownAtProcessStart() {
        let start = Date(timeIntervalSince1970: 50)
        let s = AgentResolver.status(hook: nil, screen: nil, startedAt: start, now: Date())
        XCTAssertEqual(s, StatusObservation(status: .unknown, at: start))
        let hook = HookState(agent: .pi, sessionID: nil, tty: "t", pid: 1, cwd: nil, status: .working,
                             updatedAt: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(AgentResolver.status(hook: hook, screen: nil, startedAt: start, now: Date()).status, .working)
    }
}
