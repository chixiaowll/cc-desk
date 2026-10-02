import XCTest
@testable import CCDeskCore

final class TransitionsTests: XCTestCase {
    func row(_ id: String, _ status: AgentStatus, name: String = "旅行攻略", groupTitle: String = "poems") -> SidebarRow {
        SidebarRow(session: AgentSession(id: id, kind: .claude, sessionID: id, pid: 1, tty: nil, cwd: "/a",
                                         name: name, nameIsDerived: false, host: .vscode, status: status,
                                         statusChangedAt: Date()),
                   displayName: name, groupTitle: groupTitle, subtitle: nil, sourceLabel: nil)
    }

    func testFirstSnapshotProducesNoEvents() {
        XCTAssertEqual(TransitionDetector.events(previous: nil, rows: [row("a", .waiting("x"))]), [])
    }

    func testEnteringWaitingProducesNeedsInput() {
        let ev = TransitionDetector.events(previous: ["a": .working], rows: [row("a", .waiting("Bash(ls)"))])
        XCTAssertEqual(ev, [StatusEvent(kind: .needsInput, sessionKey: "a", title: "旅行攻略 需要批准", body: "Bash(ls)")])
    }

    func testWaitingReasonDefault() {
        let ev = TransitionDetector.events(previous: ["a": .idle], rows: [row("a", .waiting(nil))])
        XCTAssertEqual(ev.first?.body, "等待输入")
    }

    func testWorkingToIdleProducesFinished() {
        let ev = TransitionDetector.events(previous: ["a": .working], rows: [row("a", .idle)])
        XCTAssertEqual(ev, [StatusEvent(kind: .finished, sessionKey: "a", title: "旅行攻略 已完成", body: "本轮已结束")])
    }

    func testNotificationNameUsesGroupTitlePrefixForShortenedDerivedNames() {
        let ev = TransitionDetector.events(previous: ["a": .working],
                                            rows: [row("a", .waiting("x"), name: "#06", groupTitle: "poems")])
        XCTAssertEqual(ev.first?.title, "poems #06 需要批准")
    }

    func testNoEventsForUnchangedNewOrOtherTransitions() {
        XCTAssertEqual(TransitionDetector.events(previous: ["a": .waiting("x")], rows: [row("a", .waiting("y"))]), [])
        XCTAssertEqual(TransitionDetector.events(previous: [:], rows: [row("new", .waiting("x"))]), [])
        XCTAssertEqual(TransitionDetector.events(previous: ["a": .unknown], rows: [row("a", .idle)]), [])
        XCTAssertEqual(TransitionDetector.events(previous: ["a": .waiting("x")], rows: [row("a", .idle)]), [])
    }
}
