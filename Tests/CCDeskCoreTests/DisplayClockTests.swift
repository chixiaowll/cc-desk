import XCTest
@testable import CCDeskCore

final class DisplayClockTests: ZhHansTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return c
    }

    private func next(_ elapsed: TimeInterval) -> TimeInterval? {
        DisplayClock.nextChange(relativeTo: base, after: base.addingTimeInterval(elapsed))?.timeIntervalSince(base)
    }

    func testRelativeTimeBoundaries() {
        XCTAssertEqual(next(0), 60)
        XCTAssertEqual(next(59), 60)
        XCTAssertEqual(next(60), 120)
        XCTAssertEqual(next(125), 180)
        XCTAssertEqual(next(3599), 3600)
        XCTAssertEqual(next(3600), 7200)
        XCTAssertEqual(next(86399), 86400)
        // 24 小时整：标签已是「1 天」，还差变灰（严格大于）。
        XCTAssertEqual(next(86400) ?? 0, 86400 + DisplayClock.epsilon, accuracy: 1e-6)
        XCTAssertEqual(next(86401), 2 * 86400)
        XCTAssertEqual(next(8 * 86400), 14 * 86400)
        XCTAssertNil(DisplayClock.nextChange(relativeTo: .distantPast, after: base))
        // 将来的时间（时钟回拨）：显示为「刚刚」，到它之后 60 秒才变。
        XCTAssertEqual(next(-30), 60)
    }

    /// 在下一次变化之前，标签与变灰都不变；到点后至少其一变化。
    func testLabelsAreConstantUntilTheNextChange() {
        for elapsed: TimeInterval in [0, 30, 61, 150, 3_000, 3_601, 50_000, 86_400, 90_000, 700_000] {
            let now = base.addingTimeInterval(elapsed)
            guard let change = DisplayClock.nextChange(relativeTo: base, after: now) else { return XCTFail("nil") }
            func state(_ t: Date) -> String {
                RelativeTime.short(from: base, now: t) + (RelativeTime.isStale(base, now: t) ? "/stale" : "")
            }
            XCTAssertEqual(state(now), state(max(now, change.addingTimeInterval(-2 * DisplayClock.epsilon))), "elapsed \(elapsed)")
            XCTAssertNotEqual(state(now), state(change), "elapsed \(elapsed)")
        }
    }

    func testResetTextBoundaries() {
        let resetsAt = base.addingTimeInterval(10 * 3600)
        func change(_ remaining: TimeInterval) -> Date? {
            DisplayClock.nextResetTextChange(resetsAt: resetsAt, after: resetsAt.addingTimeInterval(-remaining), calendar: calendar)
        }
        // 已过重置时间：不再变化。
        XCTAssertNil(change(0))
        XCTAssertNil(change(-10))
        // 最后一分钟：到点变「已重置 / —」。
        XCTAssertEqual(change(30), resetsAt)
        for remaining: TimeInterval in [30, 59, 61, 150, 3_599, 3_600, 3_601, 7_300, 21_599, 21_601, 30_000] {
            let now = resetsAt.addingTimeInterval(-remaining)
            guard let next = change(remaining) else { return XCTFail("nil at \(remaining)") }
            XCTAssertGreaterThan(next, now)
            let text = UsageResetText.text(resetsAt: resetsAt, now: now, calendar: calendar)
            // 返回的时刻比边界多 epsilon：边界之前一点（2 × epsilon）文字还没变。
            let before = next.addingTimeInterval(-2 * DisplayClock.epsilon)
            XCTAssertEqual(text, UsageResetText.text(resetsAt: resetsAt, now: before, calendar: calendar),
                           "remaining \(remaining)")
            XCTAssertNotEqual(text, UsageResetText.text(resetsAt: resetsAt, now: next, calendar: calendar),
                              "remaining \(remaining)")
        }
    }

    func testUsageAgeAndStaleness() throws {
        let usage = ClaudeUsage(planLabel: "Max", limits: [], fetchedAt: base, extraUsageEnabled: false,
                                extraUsageDisabledReason: nil)
        func change(_ age: TimeInterval) -> TimeInterval? {
            DisplayClock.nextChange(usage: usage, after: base.addingTimeInterval(age), calendar: calendar)?.timeIntervalSince(base)
        }
        XCTAssertEqual(change(10), 60)
        XCTAssertEqual(change(61), 120)
        // 30 分钟整：标签变到 31 分钟之前先变「过时」。
        XCTAssertEqual(try XCTUnwrap(change(1800)), 1800 + DisplayClock.epsilon, accuracy: 1e-6)
        XCTAssertEqual(change(4000), 7200)
    }

    func testCombinesRowsAndUsage() {
        let now = base.addingTimeInterval(1000)
        let rows = [base, base.addingTimeInterval(990), .distantPast]
        // base：已过 1000 秒 -> 1020；第二个：10 秒 -> 1050。
        XCTAssertEqual(DisplayClock.nextChange(dates: rows, usage: nil, after: now, calendar: calendar),
                       base.addingTimeInterval(1020))
        let limit = UsageLimit(kind: "session", group: nil, percent: 50, severity: .normal,
                               resetsAt: base.addingTimeInterval(1005), scopeLabel: nil, isActive: false)
        let usage = ClaudeUsage(planLabel: "", limits: [limit], fetchedAt: .distantPast, extraUsageEnabled: false,
                                extraUsageDisabledReason: nil)
        XCTAssertEqual(DisplayClock.nextChange(dates: rows, usage: usage, after: now, calendar: calendar),
                       base.addingTimeInterval(1005))
        XCTAssertNil(DisplayClock.nextChange(dates: [.distantPast], usage: nil, after: now, calendar: calendar))
    }

    /// 一个典型侧栏（几行几分钟到几小时前的会话）在一小时里需要的时钟前进次数远少于 3600。
    func testTypicalSidebarTicksRarely() {
        let dates = [base.addingTimeInterval(-30), base.addingTimeInterval(-400), base.addingTimeInterval(-7_200),
                     base.addingTimeInterval(-90_000)]
        var now = base
        var ticks = 0
        while let next = DisplayClock.nextChange(dates: dates, usage: nil, after: now, calendar: calendar),
              next < base.addingTimeInterval(3600) {
            now = next
            ticks += 1
        }
        // 60 分钟内最多每分钟两次（两行的分钟边界错开）。
        XCTAssertLessThanOrEqual(ticks, 120)
        XCTAssertGreaterThan(ticks, 0)
    }
}
