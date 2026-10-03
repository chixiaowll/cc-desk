import XCTest
@testable import CCDeskCore

final class StatusMenuTests: ZhHansTestCase {
    private func row(_ id: String, _ status: AgentStatus, kind: AgentKind = .claude, name: String = "n",
                     unread: Bool = false, host: SessionHost = .vscode) -> SidebarRow {
        let session = AgentSession(id: id, kind: kind, sessionID: id, pid: 1, tty: nil, cwd: "/r", name: name,
                                   nameIsDerived: false, host: host, status: status,
                                   statusChangedAt: Date(timeIntervalSince1970: 0))
        return SidebarRow(session: session, displayName: name, groupTitle: "g", subtitle: nil, sourceLabel: nil,
                          agentLabel: kind.isAgent ? kind.displayName : nil, unread: unread)
    }

    func testSectionsSortGroupsAndRowsByUrgencyStably() {
        let groups = [
            SessionGroup(id: "/a", title: "a", rows: [row("a1", .idle), row("a2", .working)]),
            SessionGroup(id: "/b", title: "b", rows: [row("b1", .idle), row("b2", .waiting(nil)), row("b3", .idle)]),
            SessionGroup(id: "/c", title: "c", rows: [row("c1", .idle, unread: true)]),
            SessionGroup(id: "/d", title: "d", rows: [row("d1", .working)]),
            SessionGroup(id: "/e", title: "e", rows: []),
        ]
        let sections = StatusMenu.sections(groups)
        XCTAssertEqual(sections.map(\.id), ["/b", "/c", "/a", "/d"])
        XCTAssertEqual(sections[0].entries.map(\.id), ["b2", "b1", "b3"])
        XCTAssertEqual(sections[2].entries.map(\.id), ["a2", "a1"])
    }

    func testEntryDetailAndTone() {
        let waiting = StatusMenu.entry(for: row("w", .waiting("Bash")))
        XCTAssertEqual(waiting.detail, "等批准 · Claude")
        XCTAssertEqual(waiting.tone, .waiting)
        // 等批准优先于未读。
        XCTAssertEqual(StatusMenu.entry(for: row("x", .waiting(nil), unread: true)).tone, .waiting)
        let done = StatusMenu.entry(for: row("u", .idle, unread: true))
        XCTAssertEqual(done.tone, .unread)
        XCTAssertEqual(done.detail, "已完成 · Claude")
        XCTAssertEqual(StatusMenu.entry(for: row("k", .working, kind: .codex)).detail, "处理中 · Codex")
        let shell = StatusMenu.entry(for: row("s", .unknown, kind: .other, host: .embedded(terminalID: UUID())))
        XCTAssertEqual(shell.detail, "终端")
        XCTAssertEqual(shell.tone, .inactive)
        XCTAssertEqual(StatusMenu.entry(for: row("e", .ended)).tone, .inactive)
    }

    func testEntryTitleIsSingleLineAndTruncated() {
        let long = String(repeating: "长", count: 60)
        let entry = StatusMenu.entry(for: row("l", .idle, name: "第一行\n" + long))
        XCTAssertFalse(entry.title.contains("\n"))
        XCTAssertLessThanOrEqual(entry.title.count, StatusMenu.maxTitleLength + 1)
    }

    func testBadgeTextMatchesDockCount() {
        XCTAssertEqual(StatusMenu.Badge(waiting: 0, unread: 0).text, "")
        XCTAssertTrue(StatusMenu.Badge(waiting: 0, unread: 0).isEmpty)
        let both = StatusMenu.Badge(waiting: 2, unread: 1)
        XCTAssertEqual(both.emphasizedText, "2")
        XCTAssertEqual(both.secondaryText, " · 1")
        XCTAssertEqual(both.text, "2 · 1")
        XCTAssertEqual(both.total, 3)
        XCTAssertEqual(StatusMenu.Badge(waiting: 3, unread: 0).text, "3")
        XCTAssertNil(StatusMenu.Badge(waiting: 0, unread: 4).emphasizedText)
        XCTAssertEqual(StatusMenu.Badge(waiting: 0, unread: 4).text, "4")
        XCTAssertEqual(StatusMenu.Badge(waiting: -1, unread: 0).total, 0)
    }

    func testBadgeFromGroupsCountsWaitingAndUnreadLikeDock() {
        let groups = [
            SessionGroup(id: "/a", title: "a", rows: [row("a1", .waiting(nil)), row("a2", .idle, unread: true)]),
            SessionGroup(id: "/b", title: "b", rows: [row("b1", .waiting(nil), unread: true), row("b2", .working)]),
        ]
        let badge = StatusMenu.Badge(groups: groups)
        XCTAssertEqual(badge.waiting, 2)
        XCTAssertEqual(badge.unread, 1)
    }

    func testBadgeTooltip() {
        XCTAssertEqual(StatusMenu.Badge(waiting: 2, unread: 1).tooltip, "CC Desk — 2 个等批准 · 1 个已完成未读")
        XCTAssertEqual(StatusMenu.Badge(waiting: 0, unread: 0).tooltip, "CC Desk — 没有需要处理的会话")
        Localization.languageOverride = "en"
        XCTAssertEqual(StatusMenu.Badge(waiting: 1, unread: 0).tooltip, "CC Desk — 1 waiting")
    }
}
