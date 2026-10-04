import XCTest
@testable import CCDeskCore

/// 注册表 status 的映射（含 "shell"）与未知取值的兜底。
final class RegistryStatusTests: ZhHansTestCase {
    private func entry(_ status: String?, pid: Int32 = 1, sid: String = "s") -> RegistryEntry {
        let field = status.map { #","status":"\#($0)""# } ?? ""
        let json = #"{"pid":\#(pid),"sessionId":"\#(sid)","cwd":"/a"\#(field),"waitingFor":"Bash(ls)"}"#
        guard let parsed = RegistryReader.parse(Data(json.utf8)) else {
            XCTFail("parse failed")
            return RegistryEntry(pid: 0, sessionID: "", cwd: "", name: nil, nameIsDerived: false,
                                 status: .unknown, statusUpdatedAt: .distantPast, entrypoint: nil)
        }
        return parsed
    }

    func testShellIsIdleWithBackgroundWork() {
        let e = entry("shell")
        XCTAssertEqual(e.status, .idle)
        XCTAssertTrue(e.backgroundWork)
        XCTAssertEqual(e.rawStatus, "shell")
        XCTAssertTrue(e.hasKnownStatus)
        XCTAssertFalse(entry("idle").backgroundWork)
        XCTAssertFalse(entry("busy").backgroundWork)
    }

    func testMappingTable() {
        XCTAssertEqual(RegistryReader.status(raw: "busy", waitingFor: nil)?.status, .working)
        XCTAssertEqual(RegistryReader.status(raw: "waiting", waitingFor: "x")?.status, .waiting("x"))
        XCTAssertNil(RegistryReader.status(raw: "compacting", waitingFor: nil))
        XCTAssertNil(RegistryReader.status(raw: nil, waitingFor: nil))
    }

    func testUnknownValueKeepsLastKnownStatus() {
        var memory = RegistryStatusMemory()
        XCTAssertEqual(memory.resolve([entry("busy")]).first?.status, .working)
        XCTAssertEqual(memory.resolve([entry("compacting")]).first?.status, .working)
        XCTAssertEqual(memory.resolve([entry(nil)]).first?.status, .working)
        XCTAssertEqual(memory.resolve([entry("shell")]).first?.backgroundWork, true)
        let kept = memory.resolve([entry("whatever")]).first
        XCTAssertEqual(kept?.status, .idle)
        XCTAssertEqual(kept?.backgroundWork, true)
    }

    func testUnknownAfterWaitingDegradesToWorking() {
        var memory = RegistryStatusMemory()
        _ = memory.resolve([entry("waiting")])
        let e = memory.resolve([entry("newthing")]).first
        XCTAssertEqual(e?.status, .working)
        XCTAssertEqual(e?.backgroundWork, false)
    }

    func testUnknownWithoutHistoryStaysUnknownAndMemoryIsPerSession() {
        var memory = RegistryStatusMemory()
        _ = memory.resolve([entry("busy", pid: 1, sid: "a")])
        let out = memory.resolve([entry("odd", pid: 2, sid: "b"), entry("odd", pid: 1, sid: "a")])
        XCTAssertEqual(out.map(\.status), [.unknown, .working])
        // 会话消失后忘掉：再出现时不沿用。
        _ = memory.resolve([])
        XCTAssertEqual(memory.resolve([entry("odd", pid: 1, sid: "a")]).first?.status, .unknown)
    }

    private func row(_ status: AgentStatus, background: Bool, unread: Bool = false) -> SidebarRow {
        SidebarRow(session: AgentSession(id: "a", kind: .claude, sessionID: "a", pid: 1, tty: nil, cwd: "/a",
                                         name: "x", nameIsDerived: false, host: .vscode, status: status,
                                         statusChangedAt: Date(), backgroundWork: background),
                   displayName: "x", groupTitle: "g", subtitle: nil, sourceLabel: nil, unread: unread)
    }

    func testSidebarLabelShowsBackgroundHint() {
        XCTAssertEqual(row(.idle, background: true).statusLabel, "空闲 · 后台任务")
        XCTAssertEqual(row(.idle, background: true, unread: true).statusLabel, "已完成 · 后台任务")
        XCTAssertEqual(row(.idle, background: false).statusLabel, "空闲")
        // 只在空闲时显示提示。
        XCTAssertEqual(row(.working, background: true).statusLabel, "处理中")
        XCTAssertFalse(row(.idle, background: true).session.status.isWaiting)
    }

    func testWorkingToShellIsAFinishedTurn() {
        let events = TransitionDetector.events(previous: ["a": .working], rows: [row(.idle, background: true)])
        XCTAssertEqual(events.map(\.kind), [.finished])
        // 空闲 → 后台任务：不是新的一轮。
        XCTAssertEqual(TransitionDetector.events(previous: ["a": .idle], rows: [row(.idle, background: true)]), [])
    }

    func testSessionBuilderCarriesBackgroundWork() {
        let registry = [RegistryEntry(pid: 42, sessionID: "s", cwd: "/p", name: nil, nameIsDerived: true,
                                      status: .idle, statusUpdatedAt: Date(), entrypoint: "cli",
                                      rawStatus: "shell", backgroundWork: true)]
        let processes = ProcessTable(byPID: [42: ProcInfo(pid: 42, ppid: 1, tty: nil, command: "/usr/local/bin/claude")])
        let built = SessionBuilder.build(registry: registry, processes: processes, embedded: [], missing: [],
                                         internalDirectory: "/nonexistent")
        XCTAssertEqual(built.first?.showsBackgroundWork, true)
    }
}
