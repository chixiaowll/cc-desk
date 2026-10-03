import XCTest
@testable import CCDeskCore

final class TransitionsTests: ZhHansTestCase {
    func row(_ id: String, _ status: AgentStatus, name: String = "旅行攻略", groupTitle: String = "poems",
             host: SessionHost = .vscode) -> SidebarRow {
        SidebarRow(session: AgentSession(id: id, kind: .claude, sessionID: id, pid: 1, tty: nil, cwd: "/a",
                                         name: name, nameIsDerived: false, host: host, status: status,
                                         statusChangedAt: Date()),
                   displayName: name, groupTitle: groupTitle, subtitle: nil, sourceLabel: nil)
    }

    func testFirstSnapshotProducesNoEvents() {
        XCTAssertEqual(TransitionDetector.events(previous: nil, rows: [row("a", .waiting("x"))]), [])
    }

    func testEnteringWaitingProducesNeedsInput() {
        let ev = TransitionDetector.events(previous: ["a": .working], rows: [row("a", .waiting("Bash(ls)"))])
        XCTAssertEqual(ev, [StatusEvent(kind: .needsInput, sessionKey: "a", title: "旅行攻略 需要批准", body: "Bash(ls)",
                                        reason: "Bash(ls)", actionable: false)])
    }

    func testWaitingReasonDefault() {
        let ev = TransitionDetector.events(previous: ["a": .idle], rows: [row("a", .waiting(nil))])
        XCTAssertEqual(ev.first?.body, "等待输入")
    }

    func testWorkingToIdleProducesFinished() {
        let ev = TransitionDetector.events(previous: ["a": .working], rows: [row("a", .idle)])
        XCTAssertEqual(ev, [StatusEvent(kind: .finished, sessionKey: "a", title: "旅行攻略 已完成", body: "本轮已结束")])
    }

    func testNotificationNameIsDisplayNameWithoutGroupPrefix() {
        let ev = TransitionDetector.events(previous: ["a": .working],
                                            rows: [row("a", .waiting("x"), name: "#06", groupTitle: "poems")])
        XCTAssertEqual(ev.first?.title, "#06 需要批准")
    }

    func testNoEventsForUnchangedNewOrOtherTransitions() {
        XCTAssertEqual(TransitionDetector.events(previous: ["a": .waiting("x")], rows: [row("a", .waiting("y"))]), [])
        XCTAssertEqual(TransitionDetector.events(previous: [:], rows: [row("new", .waiting("x"))]), [])
        XCTAssertEqual(TransitionDetector.events(previous: ["a": .unknown], rows: [row("a", .idle)]), [])
        XCTAssertEqual(TransitionDetector.events(previous: ["a": .waiting("x")], rows: [row("a", .idle)]), [])
    }

    func testWorkingToEndedProducesNoEvent() {
        XCTAssertEqual(TransitionDetector.events(previous: ["a": .working], rows: [row("a", .ended)]), [])
        XCTAssertEqual(TransitionDetector.events(previous: ["a": .ended], rows: [row("a", .idle)]), [])
    }

    // MARK: 通知上的批准 / 拒绝

    func testOnlyEmbeddedWaitingIsActionable() {
        let tid = UUID()
        let ev = TransitionDetector.events(previous: ["a": .working, "b": .working, "c": .working],
                                            rows: [row("a", .waiting("Bash: rm -rf build"), host: .embedded(terminalID: tid)),
                                                   row("b", .waiting("Bash: ls"), host: .terminalApp(tty: "ttys001")),
                                                   row("c", .idle, host: .embedded(terminalID: tid))])
        XCTAssertEqual(ev.map(\.actionable), [true, false, false])
        XCTAssertEqual(ev.first?.reason, "Bash: rm -rf build")
        XCTAssertEqual(ev.first?.body, "Bash: rm -rf build")
    }

    func testWaitingWithoutReasonKeepsNilReason() {
        let ev = TransitionDetector.events(previous: ["a": .idle],
                                            rows: [row("a", .waiting(nil), host: .embedded(terminalID: UUID()))])
        XCTAssertNil(ev.first?.reason)
        XCTAssertEqual(ev.first?.actionable, true)
    }

    func testLongReasonIsTruncatedInBodyButKeptInReason() {
        let long = "Bash: " + String(repeating: "x", count: 300)
        let ev = TransitionDetector.events(previous: ["a": .working], rows: [row("a", .waiting(long))])
        XCTAssertEqual(ev.first?.reason, long)
        XCTAssertEqual(ev.first?.body.count, ApprovalNotification.bodyLimit)
        XCTAssertEqual(ev.first?.body.hasSuffix("…"), true)
    }

    func testBodyCollapsesWhitespaceAndTruncates() {
        XCTAssertEqual(ApprovalNotification.body("Bash:  echo a\n  echo b"), "Bash: echo a echo b")
        XCTAssertEqual(ApprovalNotification.body("abcdefghij", limit: 5), "abcd…")
        XCTAssertEqual(ApprovalNotification.body("abc de", limit: 5), "abc…")
        XCTAssertEqual(ApprovalNotification.body("abcde", limit: 5), "abcde")
    }

    func testDecideApprovalAction() {
        let embedded = SessionHost.embedded(terminalID: UUID())
        XCTAssertEqual(ApprovalNotification.decide(expectedReason: "Bash: ls", host: embedded, status: .waiting("Bash: ls")), .apply)
        XCTAssertEqual(ApprovalNotification.decide(expectedReason: nil, host: embedded, status: .waiting(nil)), .apply)
        XCTAssertEqual(ApprovalNotification.decide(expectedReason: "Bash: ls", host: nil, status: nil), .gone)
        XCTAssertEqual(ApprovalNotification.decide(expectedReason: "Bash: ls", host: .terminalApp(tty: "ttys001"),
                                                   status: .waiting("Bash: ls")), .notEmbedded)
        XCTAssertEqual(ApprovalNotification.decide(expectedReason: "Bash: ls", host: .missing(terminalID: UUID()),
                                                   status: .waiting("Bash: ls")), .notEmbedded)
        for status in [AgentStatus.working, .idle, .ended, .unknown] {
            XCTAssertEqual(ApprovalNotification.decide(expectedReason: "Bash: ls", host: embedded, status: status), .notWaiting)
        }
        XCTAssertEqual(ApprovalNotification.decide(expectedReason: "Bash: ls", host: embedded,
                                                   status: .waiting("Bash: rm -rf /")), .reasonChanged)
        XCTAssertEqual(ApprovalNotification.decide(expectedReason: nil, host: embedded, status: .waiting("Bash: ls")), .reasonChanged)
        XCTAssertEqual(ApprovalNotification.decide(expectedReason: "Bash: ls", host: embedded, status: .waiting(nil)), .reasonChanged)
    }

    func testPermissionPromptKeys() {
        XCTAssertEqual(PermissionPrompt.keys(approve: true), "\r")
        XCTAssertEqual(PermissionPrompt.keys(approve: false), "\u{1b}")
    }
}
