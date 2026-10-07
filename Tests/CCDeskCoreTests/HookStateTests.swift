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
        XCTAssertNil(HookStateReader.parse(json(#"{"agent":"codex","tty":"","session_id":"","status":"idle","ts":1}"#)))
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
        try json(#"{"agent":"codex","tty":"","session_id":"sid-9","pid":0,"status":"idle","ts":3000}"#).write(to: dir.appendingPathComponent("codex-sid-9.json"))
        try json(#"{"agent":"pi","tty":"ttys005","status":"idle","ts":1000}"#).write(to: dir.appendingPathComponent(".ttys005.123.tmp.json"))
        let all = HookStateReader.readAll(directory: dir)
        XCTAssertEqual(Set(all.byTTY.keys), ["ttys001", "ttys002"])
        XCTAssertEqual(all.byTTY["ttys001"]?.status, .working)
        XCTAssertEqual(Set(all.bySession.keys), ["codex:sid-9"])
        XCTAssertNil(all.bySession["codex:sid-9"]?.pid, "pid 0 means unknown")
        XCTAssertNil(all.bySession["codex:sid-9"]?.tty)
    }

    func testPruneRemovesOnlyOldFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("codex-old.json"), fresh = dir.appendingPathComponent("ttys001.json")
        let other = dir.appendingPathComponent("keep.txt")
        for url in [old, fresh, other] { try json("{}").write(to: url) }
        let longAgo = Date().addingTimeInterval(-30 * 86400)
        for url in [old, other] { try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: url.path) }
        HookStateReader.prune(directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testLookupBySessionWhenHookHasNoTTY() {
        let start = Date(timeIntervalSince1970: 1000)
        let states = HookStates([
            HookState(agent: .codex, sessionID: "s1", tty: nil, pid: nil, cwd: nil, status: .working, updatedAt: Date(timeIntervalSince1970: 1500)),
            HookState(agent: .codex, sessionID: "old", tty: nil, pid: nil, cwd: nil, status: .working, updatedAt: Date(timeIntervalSince1970: 500)),
            HookState(agent: .pi, sessionID: "p1", tty: "ttys009", pid: 42, cwd: nil, status: .idle, updatedAt: Date(timeIntervalSince1970: 10)),
        ])
        XCTAssertEqual(states.state(kind: .codex, pid: 7, tty: "ttys001", sessionID: "s1", processStart: start)?.status, .working)
        XCTAssertNil(states.state(kind: .codex, pid: 7, tty: "ttys001", sessionID: "old", processStart: start), "written before this process started")
        XCTAssertNil(states.state(kind: .codex, pid: 7, tty: "ttys001", sessionID: nil, processStart: start))
        XCTAssertEqual(states.state(kind: .pi, pid: 42, tty: "ttys009", sessionID: nil, processStart: start)?.status, .idle)
        XCTAssertNil(states.state(kind: .pi, pid: 43, tty: "ttys009", sessionID: nil, processStart: start))
        XCTAssertEqual(states.state(kind: .pi, pid: 42, tty: nil, sessionID: "p1", processStart: start)?.status, .idle)
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
        let r = StatusMerger.merge(hook: obs(.working, 1000), screen: obs(.idle, 1100), now: Date(timeIntervalSince1970: 1110))
        XCTAssertEqual(r?.status, .working)
    }

    /// 重启后屏幕还没识别：停在处理中超过 10 分钟的 hook 当作未知；新鲜的照常。
    func testStaleWorkingHookWithoutScreenIsUnknown() {
        XCTAssertEqual(StatusMerger.merge(hook: obs(.working, 1000), screen: nil, now: Date(timeIntervalSince1970: 1700)),
                       obs(.unknown, 1000))
        XCTAssertEqual(StatusMerger.merge(hook: obs(.working, 1000), screen: nil, now: Date(timeIntervalSince1970: 1100))?.status,
                       .working)
        XCTAssertEqual(StatusMerger.merge(hook: obs(.idle, 1000), screen: nil, now: Date(timeIntervalSince1970: 9000))?.status, .idle)
        XCTAssertTrue(StartupGrace.suppressesFinished(uptime: 110, launchedAt: 100))
        XCTAssertFalse(StartupGrace.suppressesFinished(uptime: 130, launchedAt: 100))
    }

    /// 请求报错 / Esc 打断：hook 停在处理中，屏幕回到空闲 15 秒后按空闲算（从 hook 与屏幕较晚的时间算起）。
    func testWorkingHookWithLastingIdleScreenEnds() {
        // 处理中阶段太短，屏幕没来得及变：屏幕的空闲比 hook 还早，从 hook 时间算。
        XCTAssertEqual(StatusMerger.merge(hook: obs(.working, 1000), screen: obs(.idle, 900), now: Date(timeIntervalSince1970: 1010))?.status,
                       .working)
        XCTAssertEqual(StatusMerger.merge(hook: obs(.working, 1000), screen: obs(.idle, 900), now: Date(timeIntervalSince1970: 1016)),
                       obs(.idle, 1000))
        XCTAssertEqual(StatusMerger.merge(hook: obs(.working, 1000), screen: obs(.idle, 1020), now: Date(timeIntervalSince1970: 1040)),
                       obs(.idle, 1020))
        // 屏幕显示处理中：hook 照常。
        XCTAssertEqual(StatusMerger.merge(hook: obs(.working, 1000), screen: obs(.working, 1001), now: Date(timeIntervalSince1970: 1300))?.status,
                       .working)
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

    func testScreenClearsStaleHookWaiting() {
        let r = StatusMerger.merge(hook: obs(.waiting(nil), 1000), screen: obs(.working, 1005), now: Date(timeIntervalSince1970: 1006))
        XCTAssertEqual(r?.status, .working)
        let keep = StatusMerger.merge(hook: obs(.waiting(nil), 1000), screen: obs(.working, 990), now: Date(timeIntervalSince1970: 1006))
        XCTAssertEqual(keep?.status, .waiting(nil))
    }

    func testSingleSources() {
        XCTAssertEqual(StatusMerger.merge(hook: nil, screen: obs(.working, 1), now: Date())?.status, .working)
        XCTAssertEqual(StatusMerger.merge(hook: obs(.idle, 1), screen: nil, now: Date())?.status, .idle)
        XCTAssertNil(StatusMerger.merge(hook: nil, screen: nil, now: Date()))
    }
}
