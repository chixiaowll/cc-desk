import XCTest
@testable import CCDeskCore

final class HistoryGroupingTests: ZhHansTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func item(_ id: String, cwd: String = "/a", at: Date) -> HistoryItem {
        HistoryItem(sessionID: id, cwd: cwd, title: id, lastPrompt: nil, modifiedAt: at)
    }

    func testByDaySplitsIntoTodayYesterdayAndEarlier() {
        let cal = calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!
        let todayEarlier = cal.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 1))!
        let yesterday = cal.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 23))!
        let twoDaysAgo = cal.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 10))!

        let groups = HistoryGrouping.byDay([
            item("earlier", at: twoDaysAgo),
            item("today-old", at: todayEarlier),
            item("today-new", at: now),
            item("yesterday", at: yesterday),
        ], now: now, calendar: cal)

        XCTAssertEqual(groups.map(\.label), ["今天", "昨天", "更早"])
        XCTAssertEqual(groups[0].items.map(\.id), ["today-new", "today-old"])
        XCTAssertEqual(groups[1].items.map(\.id), ["yesterday"])
        XCTAssertEqual(groups[2].items.map(\.id), ["earlier"])
    }

    func testByDayOmitsEmptyGroups() {
        let cal = calendar
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!
        let groups = HistoryGrouping.byDay([item("a", at: now)], now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.label), ["今天"])
    }

    func testByDayReturnsEmptyArrayForNoItems() {
        let groups = HistoryGrouping.byDay([], now: Date(), calendar: calendar)
        XCTAssertTrue(groups.isEmpty)
    }

    func testByDayUsesInjectableCalendarDefaultingToCurrent() {
        // 不传 calendar 时应使用 .current，而不是编译期崩溃；这里只验证签名可用且不抛错。
        let now = Date()
        let groups = HistoryGrouping.byDay([item("a", at: now)], now: now)
        XCTAssertEqual(groups.first?.label, "今天")
    }

    func testForProjectFiltersByResolvedRootAndSortsNewestFirst() {
        let projects: [String: ProjectRef] = [
            "/r/herdr": ProjectRef(root: "/r/herdr", branch: nil, cwd: "/r/herdr"),
            "/wt/fix": ProjectRef(root: "/r/herdr", branch: "issue/1", cwd: "/wt/fix"),
            "/r/poems": ProjectRef(root: "/r/poems", branch: nil, cwd: "/r/poems"),
        ]
        let resolve: (String) -> ProjectRef = { projects[$0] ?? ProjectRef(root: $0, branch: nil, cwd: $0) }

        let old = item("old", cwd: "/r/herdr", at: Date(timeIntervalSince1970: 1))
        let new = item("new", cwd: "/wt/fix", at: Date(timeIntervalSince1970: 2))
        let other = item("other", cwd: "/r/poems", at: Date(timeIntervalSince1970: 3))

        let result = HistoryGrouping.forProject(root: "/r/herdr", items: [old, new, other], project: resolve)
        XCTAssertEqual(result.map(\.id), ["new", "old"])
    }

    func testForProjectReturnsEmptyWhenNoneMatch() {
        let resolve: (String) -> ProjectRef = { ProjectRef(root: $0, branch: nil, cwd: $0) }
        let result = HistoryGrouping.forProject(root: "/nope", items: [item("a", cwd: "/r/a", at: Date())], project: resolve)
        XCTAssertTrue(result.isEmpty)
    }
}
