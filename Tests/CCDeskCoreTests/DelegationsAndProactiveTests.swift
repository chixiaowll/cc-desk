import XCTest
@testable import CCDeskCore

final class DelegationsTests: XCTestCase {
    private func delegation(_ row: String, at t: Date = Date(timeIntervalSince1970: 0)) -> Delegation {
        Delegation(rowID: row, terminalID: row, sessionID: nil, project: "/p", task: "跑测试", agent: "claude",
                   profile: "tester", startedAt: t)
    }

    func testTracksStatusSessionIDAndClosing() {
        var book = DelegationBook()
        let t = Date(timeIntervalSince1970: 100)
        book.add(delegation("term:a"))
        book.add(delegation("term:b"))
        XCTAssertTrue(book.isDelegated("term:a"))
        XCTAssertFalse(book.isDelegated("term:z"))

        // 刚启动（unknown）不改变状态。
        XCTAssertFalse(book.update(observations: [.init(rowID: "term:a", status: .unknown, sessionID: nil)],
                                   liveRowIDs: ["term:a", "term:b"], now: t))
        XCTAssertEqual(book.active(rowID: "term:a")?.state, .working)

        XCTAssertTrue(book.update(observations: [.init(rowID: "term:a", status: .waiting("Bash ls"), sessionID: "sid-1")],
                                  liveRowIDs: ["term:a", "term:b"], now: t))
        XCTAssertEqual(book.active(rowID: "term:a")?.state, .waiting)
        XCTAssertEqual(book.active(rowID: "term:a")?.sessionID, "sid-1")

        // b 的终端关了。
        XCTAssertTrue(book.update(observations: [], liveRowIDs: ["term:a"], now: t))
        XCTAssertFalse(book.isDelegated("term:b"))
        XCTAssertEqual(book.items.first { $0.rowID == "term:b" }?.state, .closed)

        // 已关闭的记录过期后删除。
        XCTAssertTrue(book.update(observations: [], liveRowIDs: ["term:a"],
                                  now: t.addingTimeInterval(DelegationBook.closedRetention + 1)))
        XCTAssertEqual(book.items.map(\.rowID), ["term:a"])
    }

    func testKeepsNewestAndPersists() throws {
        var book = DelegationBook()
        for i in 0..<(DelegationBook.keep + 3) { book.add(delegation("term:\(i)")) }
        XCTAssertEqual(book.items.count, DelegationBook.keep)
        XCTAssertEqual(book.items.first?.rowID, "term:\(DelegationBook.keep + 2)")
        book.add(delegation("term:\(DelegationBook.keep + 2)"))
        XCTAssertEqual(book.items.filter { $0.rowID == "term:\(DelegationBook.keep + 2)" }.count, 1, "re-adding replaces")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deleg-\(UUID().uuidString)/delegations.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = DelegationStore(url: url)
        XCTAssertEqual(store.load(), DelegationBook(), "missing file = empty")
        store.save(book)
        XCTAssertEqual(store.load(), book)
        try "garbage".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), DelegationBook(), "unreadable file = empty")
    }

    func testDelegateCommand() {
        XCTAssertEqual(DelegateCommand.claude(task: "跑一下测试", sessionID: "abc", profile: nil),
                       "claude --session-id 'abc' '跑一下测试'")
        XCTAssertEqual(DelegateCommand.claude(task: "it's\nfine", sessionID: "abc", profile: ("tester", "/x/tester.json")),
                       "claude --session-id 'abc' --agents \"$(cat '/x/tester.json')\" --agent 'tester' 'it'\\''s fine'")
        XCTAssertEqual(DelegateCommand.claude(task: "-v", sessionID: "s", profile: nil), "claude --session-id 's' ' -v'")
    }
}

final class ProactiveTests: XCTestCase {
    func testPolicy() {
        let approval = ProactivePolicy.Trigger.needsApproval(reason: "Bash rm -rf build")
        XCTAssertTrue(ProactivePolicy.shouldNotify(approval, isSelected: false, isDelegated: false, conversationOn: true))
        XCTAssertFalse(ProactivePolicy.shouldNotify(approval, isSelected: false, isDelegated: true, conversationOn: false),
                       "conversation mode off: normal notifications only")
        XCTAssertFalse(ProactivePolicy.shouldNotify(approval, isSelected: true, isDelegated: true, conversationOn: true),
                       "the selected session is announced by the existing flow")
        XCTAssertTrue(ProactivePolicy.shouldNotify(.finished, isSelected: false, isDelegated: true, conversationOn: true))
        XCTAssertFalse(ProactivePolicy.shouldNotify(.finished, isSelected: false, isDelegated: false, conversationOn: true),
                       "finished turns of other sessions stay silent")
    }

    private func item(_ key: String, _ kind: ProactiveSpeechGate.Item.Kind = .finished, at t: TimeInterval, _ text: String = "x")
        -> ProactiveSpeechGate.Item {
        .init(key: key, kind: kind, text: text, enqueuedAt: t)
    }

    func testGateWaitsWhileBusyAndRateLimits() {
        var gate = ProactiveSpeechGate(globalInterval: 8, perKeyInterval: 30, maxAge: 120)
        gate.enqueue(item("a", at: 0))
        XCTAssertNil(gate.next(now: 1, busy: true), "never interrupt the user")
        XCTAssertEqual(gate.next(now: 2, busy: false)?.key, "a")
        gate.enqueue(item("b", at: 3))
        XCTAssertNil(gate.next(now: 5, busy: false), "global interval")
        XCTAssertEqual(gate.next(now: 10, busy: false)?.key, "b")
        gate.enqueue(item("a", at: 11))
        XCTAssertNil(gate.next(now: 25, busy: false), "same session again within 30 s")
        XCTAssertEqual(gate.next(now: 33, busy: false)?.key, "a")
        XCTAssertTrue(gate.isEmpty)
    }

    func testGateConsultBypassesPerKeyAndItemsExpire() {
        var gate = ProactiveSpeechGate(globalInterval: 8, perKeyInterval: 30, maxAge: 120)
        gate.enqueue(item("s1", .approval(reason: "r"), at: 0))
        XCTAssertNotNil(gate.next(now: 0, busy: false))
        gate.enqueue(item("s1", .approval(reason: "r2"), at: 1))
        gate.enqueue(item("consult:c1", .consult, at: 1))
        XCTAssertEqual(gate.next(now: 9, busy: false)?.key, "consult:c1", "consult results are not held by the per-session limit")
        // 等太久的条目被丢弃。
        XCTAssertNil(gate.next(now: 200, busy: false))
        XCTAssertTrue(gate.isEmpty)
    }

    func testGateReplacesSameKindAndCapsQueue() {
        var gate = ProactiveSpeechGate(globalInterval: 0, perKeyInterval: 0, maxAge: 1000, capacity: 3)
        gate.enqueue(item("a", .approval(reason: "old"), at: 0, "old"))
        gate.enqueue(item("a", .approval(reason: "new"), at: 1, "new"))
        XCTAssertEqual(gate.queue.map(\.text), ["new"])
        gate.enqueue(item("consult:c1", .consult, at: 2))
        gate.enqueue(item("b", at: 3))
        gate.enqueue(item("c", at: 4))
        XCTAssertEqual(gate.queue.map(\.key), ["consult:c1", "b", "c"], "drops the oldest non-consult item")
        gate.drop(key: "b")
        XCTAssertEqual(gate.queue.map(\.key), ["consult:c1", "c"])
    }

    func testAnnouncedApprovalWindowAndSilence() {
        let a = AnnouncedApproval(rowID: "term:x", name: "poems", reason: "Bash ls", at: 100)
        XCTAssertTrue(a.isFresh(now: 100 + AnnouncedApproval.window))
        XCTAssertFalse(a.isFresh(now: 101 + AnnouncedApproval.window))
        XCTAssertTrue(AssistantPrompt.isSilent("SILENT"))
        XCTAssertTrue(AssistantPrompt.isSilent(" silent. "))
        XCTAssertTrue(AssistantPrompt.isSilent(""))
        XCTAssertFalse(AssistantPrompt.isSilent("poems 想执行 ls，要批准吗？"))
    }

    func testEventAndConsultMessages() {
        let event = AssistantPrompt.residentEvent("Session s3 is waiting_for_approval.", language: "zh-Hans", contextJSON: nil)
        XCTAssertEqual(event, "[EVENT] uiLanguage=zh-Hans\nSession s3 is waiting_for_approval.\nContext: unchanged")
        let long = String(repeating: "x", count: AssistantPrompt.answerLimit + 10)
        let consult = AssistantPrompt.residentConsultResult(job: "c1", question: "why", model: "sonnet", answer: long,
                                                            language: "en")
        XCTAssertTrue(consult.hasPrefix("[CONSULT_RESULT] uiLanguage=en job=c1 model=sonnet\nQuestion: why\nAnswer:\n"))
        XCTAssertTrue(consult.hasSuffix("…(truncated)"))
        XCTAssertGreaterThan(AssistantPrompt.residentVersion, 2, "prompt changed in v1.4: the stored session must rotate")
        for tool in ["consult", "delegate", "list_agents"] {
            XCTAssertTrue(AssistantPrompt.residentSystem.contains(tool))
            XCTAssertNotNil(AssistantTools.spec(named: tool))
        }
    }

    func testSessionInfoMarksDelegatedTasks() {
        let info = AssistantSessionInfo(rowID: "term:a", shortID: "s1", title: "t", dir: "poems", agent: .claude,
                                        status: .idle, isSelected: false, delegatedTask: "跑测试")
        XCTAssertEqual(info.json["delegatedTask"], "跑测试")
        let plain = AssistantSessionInfo(rowID: "term:b", shortID: "s2", title: "t", dir: "poems", agent: .claude,
                                         status: .idle, isSelected: false)
        XCTAssertNil(plain.json["delegatedTask"])
    }
}
