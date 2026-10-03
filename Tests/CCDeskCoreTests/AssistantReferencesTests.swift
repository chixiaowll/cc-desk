import XCTest
@testable import CCDeskCore

final class AssistantReferencesTests: XCTestCase {
    private let sessions = [
        AssistantSessionInfo(rowID: "term:A", shortID: "s1", title: "中国诗歌视频课程", dir: "poems", agent: .claude,
                             status: .idle, isSelected: true),
        AssistantSessionInfo(rowID: "term:B", shortID: "s2", title: "修复侧栏排序", dir: "herdr", agent: .codex,
                             status: .working, isSelected: false),
        AssistantSessionInfo(rowID: "term:C", shortID: "s5", title: "README 改写", dir: "herdr", agent: .claude,
                             status: .waiting("Bash: ls"), isSelected: false),
        AssistantSessionInfo(rowID: "pid:9", shortID: "s7", title: "旅行攻略生成", dir: "rec", agent: .pi,
                             status: .idle, isSelected: false, isEmbedded: false),
    ]

    private func found(_ ref: String?) -> String? {
        if case .found(let s) = AssistantReferences.session(ref, in: sessions) { return s.rowID }
        return nil
    }

    func testShortAndRealIDs() {
        XCTAssertEqual(found("s2"), "term:B")
        XCTAssertEqual(found(" S5 "), "term:C")
        XCTAssertEqual(found("pid:9"), "pid:9")
        XCTAssertNil(found("s9"))
    }

    func testCurrentMeansSelected() {
        XCTAssertEqual(found(nil), "term:A")
        XCTAssertEqual(found(""), "term:A")
        XCTAssertEqual(found("current"), "term:A")
        XCTAssertEqual(found("这个"), "term:A")
        let none = sessions.map { AssistantSessionInfo(rowID: $0.rowID, shortID: $0.shortID, title: $0.title, dir: $0.dir,
                                                       agent: $0.agent, status: $0.status, isSelected: false) }
        XCTAssertEqual(AssistantReferences.session(nil, in: none), .notFound)
    }

    func testFuzzyByTitleDirAgent() {
        XCTAssertEqual(found("poems"), "term:A")
        XCTAssertEqual(found("poems 那个"), "term:A")
        XCTAssertEqual(found("poems那个会话"), "term:A")
        XCTAssertEqual(found("诗歌"), "term:A")
        XCTAssertEqual(found("readme"), "term:C")
        XCTAssertEqual(found("herdr codex"), "term:B")
        XCTAssertEqual(found("旅行攻略"), "pid:9")
        XCTAssertNil(found("不存在的东西"))
    }

    func testAmbiguousReturnsCandidates() {
        guard case .ambiguous(let candidates) = AssistantReferences.session("herdr", in: sessions) else {
            return XCTFail("expected ambiguous")
        }
        XCTAssertEqual(candidates.map(\.shortID), ["s2", "s5"])
        let message = AssistantReferences.ambiguity("herdr", candidates)
        XCTAssertTrue(message.contains("s2 herdr / 修复侧栏排序 (codex, working)"))
        XCTAssertTrue(message.contains("s5 herdr / README 改写 (claude, waiting_for_approval)"))
        // 只有一个目录完全相同时直接选中（标题里含 herd 的另一个不算）。
        let mixed = [sessions[0], sessions[1],
                     AssistantSessionInfo(rowID: "x", shortID: "s9", title: "herdr 文档", dir: "docs", agent: .pi,
                                          status: .idle, isSelected: false)]
        XCTAssertEqual(AssistantReferences.session("herdr", in: mixed), .found(mixed[1]))
    }

    func testHistoryReferences() {
        let history = [
            AssistantHistoryInfo(sessionID: "uuid-1", shortID: "h1", title: "旅行攻略生成", dir: "rec", agent: .claude),
            AssistantHistoryInfo(sessionID: "uuid-2", shortID: "h2", title: "旅行攻略的测试", dir: "rec", agent: .codex),
            AssistantHistoryInfo(sessionID: "uuid-3", shortID: "h3", title: "侧栏动画", dir: "herdr", agent: .claude),
        ]
        XCTAssertEqual(AssistantReferences.history("h3", in: history), .found(history[2]))
        XCTAssertEqual(AssistantReferences.history("uuid-2", in: history), .found(history[1]))
        XCTAssertEqual(AssistantReferences.history("侧栏", in: history), .found(history[2]))
        XCTAssertEqual(AssistantReferences.history("旅行攻略生成", in: history), .found(history[0]))
        XCTAssertEqual(AssistantReferences.history("旅行攻略", in: history), .ambiguous([history[0], history[1]]))
        XCTAssertEqual(AssistantReferences.history("", in: history), .notFound)
    }

    func testProjectReferences() {
        let projects = [AssistantProject(name: "herdr", path: "/Users/u/herdr"),
                        AssistantProject(name: "poems", path: "/Users/u/poems"),
                        AssistantProject(name: "poems-web", path: "/Users/u/poems-web")]
        XCTAssertEqual(AssistantReferences.project("HERDR", in: projects), .found(projects[0]))
        XCTAssertEqual(AssistantReferences.project("/Users/u/poems/", in: projects), .found(projects[1]))
        XCTAssertEqual(AssistantReferences.project("poems", in: projects), .found(projects[1]))
        XCTAssertEqual(AssistantReferences.project("web", in: projects), .found(projects[2]))
        XCTAssertEqual(AssistantReferences.project("poe", in: projects), .ambiguous([projects[1], projects[2]]))
        XCTAssertEqual(AssistantReferences.project("rust", in: projects), .notFound)
    }

    func testShortIDsAreStableAndNeverReused() {
        var ids = ShortIDRegistry(prefix: "s")
        XCTAssertEqual(ids.id(for: "term:A"), "s1")
        XCTAssertEqual(ids.id(for: "term:B"), "s2")
        XCTAssertEqual(ids.id(for: "term:A"), "s1")
        XCTAssertEqual(ids.id(for: "term:C"), "s3")
        XCTAssertEqual(ids.key(for: "S2"), "term:B")
        XCTAssertNil(ids.key(for: "s9"))
    }
}

final class UndoLedgerTests: XCTestCase {
    private let t1 = UUID()
    private let t2 = UUID()

    func testPopsMostRecentFirst() {
        var ledger = UndoLedger()
        ledger.record(.created(rowID: "term:x", title: "herdr"), now: 0)
        ledger.record(.switched(from: "term:a", title: "poems"), now: 1)
        ledger.record(.typed(terminalID: t1, text: "跑测试", title: "poems"), now: 2)
        XCTAssertEqual(ledger.pop(now: 3), .typed(terminalID: t1, text: "跑测试", title: "poems"))
        XCTAssertEqual(ledger.pop(now: 3), .switched(from: "term:a", title: "poems"))
        XCTAssertEqual(ledger.pop(now: 3), .created(rowID: "term:x", title: "herdr"))
        XCTAssertNil(ledger.pop(now: 3))
    }

    func testSubmittedTypingIsNoLongerUndoable() {
        var ledger = UndoLedger()
        ledger.record(.typed(terminalID: t1, text: "a", title: "p"), now: 0)
        ledger.record(.typed(terminalID: t2, text: "b", title: "q"), now: 1)
        ledger.record(.typed(terminalID: t1, text: "c", title: "p"), now: 2)
        ledger.typingFinished(terminalID: t1)
        XCTAssertEqual(ledger.pop(now: 3), .typed(terminalID: t2, text: "b", title: "q"))
        XCTAssertNil(ledger.pop(now: 3))
    }

    func testClosedSessionsAndExpiryAndLimit() {
        var ledger = UndoLedger()
        ledger.record(.created(rowID: "term:\(t1.uuidString)", title: "a"), now: 0)
        ledger.record(.switched(from: "term:\(t1.uuidString)", title: "a"), now: 0)
        ledger.record(.typed(terminalID: t1, text: "x", title: "a"), now: 0)
        ledger.sessionClosed(rowID: "term:\(t1.uuidString)", terminalID: t1)
        XCTAssertTrue(ledger.isEmpty)

        ledger.record(.created(rowID: "old", title: "a"), now: 0)
        XCTAssertNil(ledger.pop(now: UndoLedger.ttl + 1))

        for i in 0..<(UndoLedger.limit + 5) { ledger.record(.created(rowID: "r\(i)", title: ""), now: 10) }
        var popped = 0
        while ledger.pop(now: 10) != nil { popped += 1 }
        XCTAssertEqual(popped, UndoLedger.limit)
    }
}
