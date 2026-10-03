import XCTest
@testable import CCDeskCore

final class HookStateTests: XCTestCase {
    func json(_ s: String) -> Data { Data(s.utf8) }

    func testParsesWaitingWithMessageAndMillis() {
        let s = HookStateReader.parse(json(#"{"agent":"codex","session_id":"sid","tty":"ttys007","pid":123,"cwd":"/w","status":"waiting","message":"allow command?","ts":1790922468588}"#))
        XCTAssertEqual(s?.agent, .codex)
        XCTAssertEqual(s?.sessionID, "sid")
        XCTAssertEqual(s?.tty, "ttys007")
        XCTAssertEqual(s?.pid, 123)
        XCTAssertEqual(s?.cwd, "/w")
        XCTAssertEqual(s?.status, .waiting("allow command?"))
        XCTAssertEqual(s?.updatedAt, Date(timeIntervalSince1970: 1790922468.588))
    }

    func testParsesSecondsAndStringPidAndEmptyFields() {
        let s = HookStateReader.parse(json(#"{"agent":"pi","session_id":"","tty":"ttys001","pid":"77","status":"idle","message":"","ts":1790922468}"#))
        XCTAssertEqual(s?.status, .idle)
        XCTAssertNil(s?.sessionID)
        XCTAssertEqual(s?.pid, 77)
        XCTAssertEqual(s?.updatedAt, Date(timeIntervalSince1970: 1790922468))
    }

    func testRejectsInvalid() {
        XCTAssertNil(HookStateReader.parse(json(#"{"agent":"codex","tty":"ttys1","status":"busy","ts":1}"#)))
        XCTAssertNil(HookStateReader.parse(json(#"{"agent":"other","tty":"ttys1","status":"idle","ts":1}"#)))
        XCTAssertNil(HookStateReader.parse(json(#"{"agent":"codex","status":"idle","ts":1}"#)))
        XCTAssertNil(HookStateReader.parse(json(#"{"agent":"codex","tty":"ttys1","status":"idle"}"#)))
        XCTAssertNil(HookStateReader.parse(json("not json")))
    }

    func testReadAllKeysByTTY() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try json(#"{"agent":"codex","tty":"ttys001","status":"working","ts":2000}"#).write(to: dir.appendingPathComponent("ttys001.json"))
        try json(#"{"agent":"pi","tty":"ttys002","status":"idle","ts":1000}"#).write(to: dir.appendingPathComponent("ttys002.json"))
        try json("garbage").write(to: dir.appendingPathComponent("ttys003.json"))
        try json(#"{"agent":"pi","tty":"ttys004","status":"idle","ts":1000}"#).write(to: dir.appendingPathComponent("ttys004.json.tmp"))
        let all = HookStateReader.readAll(directory: dir)
        XCTAssertEqual(Set(all.keys), ["ttys001", "ttys002"])
        XCTAssertEqual(all["ttys001"]?.status, .working)
    }

    // MARK: 归属

    func hook(pid: Int32? = 10, tty: String = "ttys001", at: TimeInterval, agent: AgentKind = .codex) -> HookState {
        HookState(agent: agent, sessionID: "s", tty: tty, pid: pid, cwd: nil, status: .idle, updatedAt: Date(timeIntervalSince1970: at))
    }

    func testHookAppliesByPidOrAfterProcessStart() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(StatusMerger.hookApplies(hook(at: 10), kind: .codex, pid: 10, tty: "ttys001", processStart: start))
        XCTAssertTrue(StatusMerger.hookApplies(hook(pid: 99, at: 1500), kind: .codex, pid: 10, tty: "ttys001", processStart: start))
        XCTAssertFalse(StatusMerger.hookApplies(hook(pid: 99, at: 500), kind: .codex, pid: 10, tty: "ttys001", processStart: start))
        XCTAssertFalse(StatusMerger.hookApplies(hook(at: 1500), kind: .pi, pid: 10, tty: "ttys001", processStart: start))
        XCTAssertFalse(StatusMerger.hookApplies(hook(at: 1500), kind: .codex, pid: 10, tty: "ttys002", processStart: start))
        XCTAssertFalse(StatusMerger.hookApplies(hook(at: 1500), kind: .codex, pid: 10, tty: nil, processStart: start))
    }

    // MARK: 合并

    func obs(_ s: AgentStatus, _ t: TimeInterval) -> StatusObservation { StatusObservation(status: s, at: Date(timeIntervalSince1970: t)) }

    func testHookWinsOverScreenWhenFresh() {
        let r = StatusMerger.merge(hook: obs(.working, 1000), screen: obs(.idle, 1100), now: Date(timeIntervalSince1970: 1200))
        XCTAssertEqual(r?.status, .working)
    }

    func testStaleHookFallsBackToNewerScreen() {
        let r = StatusMerger.merge(hook: obs(.working, 1000), screen: obs(.idle, 1700), now: Date(timeIntervalSince1970: 1700))
        XCTAssertEqual(r?.status, .idle)
        // 屏幕没有比 hook 更新：仍用 hook（例如长时间空闲）。
        let keep = StatusMerger.merge(hook: obs(.idle, 1000), screen: obs(.idle, 900), now: Date(timeIntervalSince1970: 9000))
        XCTAssertEqual(keep, obs(.idle, 1000))
    }

    func testScreenWaitingNewerThanHookWins() {
        let r = StatusMerger.merge(hook: obs(.working, 1000), screen: obs(.waiting("allow command?"), 1010), now: Date(timeIntervalSince1970: 1020))
        XCTAssertEqual(r?.status, .waiting("allow command?"))
        let older = StatusMerger.merge(hook: obs(.working, 1000), screen: obs(.waiting(nil), 990), now: Date(timeIntervalSince1970: 1020))
        XCTAssertEqual(older?.status, .working)
    }

    func testSingleSources() {
        XCTAssertEqual(StatusMerger.merge(hook: nil, screen: obs(.working, 1), now: Date())?.status, .working)
        XCTAssertEqual(StatusMerger.merge(hook: obs(.idle, 1), screen: nil, now: Date())?.status, .idle)
        XCTAssertNil(StatusMerger.merge(hook: nil, screen: nil, now: Date()))
    }
}
