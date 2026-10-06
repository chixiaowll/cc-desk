import XCTest
@testable import CCDeskCore

final class PollCadenceTests: XCTestCase {
    func testFastOnlyWhileTheUserIsLooking() {
        XCTAssertEqual(PollCadence.interval(PollConditions(appActive: true, windowVisible: true)), PollCadence.fast)
        XCTAssertEqual(PollCadence.interval(PollConditions(appActive: false, windowVisible: true)), PollCadence.slow)
        XCTAssertEqual(PollCadence.interval(PollConditions(appActive: true, windowVisible: false)), PollCadence.slow)
        XCTAssertEqual(PollCadence.interval(PollConditions(appActive: true, windowVisible: true, screenLocked: true)),
                       PollCadence.slow)
        XCTAssertEqual(PollCadence.interval(PollConditions(appActive: true, windowVisible: true, displayAsleep: true)),
                       PollCadence.slow)
        XCTAssertGreaterThanOrEqual(PollCadence.slow, 3)
        XCTAssertLessThanOrEqual(PollCadence.slow, 5)
    }

    func testRegularDelayCountsFromThePreviousPollStart() {
        XCTAssertEqual(PollCadence.delay(elapsed: 0.2, interval: 1, changed: false), 0.8, accuracy: 1e-9)
        XCTAssertEqual(PollCadence.delay(elapsed: 1.5, interval: 4, changed: false), 2.5, accuracy: 1e-9)
        // 已经超过间隔（如从慢档切回快档）：立即。
        XCTAssertEqual(PollCadence.delay(elapsed: 3, interval: 1, changed: false), 0)
    }

    func testChangesPollSoonButNotBackToBack() {
        XCTAssertEqual(PollCadence.delay(elapsed: 0.1, interval: 4, changed: true), PollCadence.minGap - 0.1, accuracy: 1e-9)
        XCTAssertEqual(PollCadence.delay(elapsed: 2, interval: 4, changed: true), 0)
        // 时钟异常（elapsed 为负）不会排出比间隔更长的等待。
        XCTAssertEqual(PollCadence.delay(elapsed: -5, interval: 1, changed: false), 1)
    }

    /// 最坏延迟：文件驱动的状态变化 ≤ minGap（另加 FSEvents 0.2 秒合并）；其余 ≤ 当前间隔。
    func testWorstCaseDelays() {
        for elapsed in stride(from: 0.0, through: 4.0, by: 0.1) {
            XCTAssertLessThanOrEqual(PollCadence.delay(elapsed: elapsed, interval: PollCadence.slow, changed: true),
                                     PollCadence.minGap)
            XCTAssertLessThanOrEqual(PollCadence.delay(elapsed: elapsed, interval: PollCadence.slow, changed: false),
                                     PollCadence.slow)
        }
    }

    func testToleranceIsAFractionOfTheInterval() {
        XCTAssertEqual(PollCadence.tolerance(for: 1), 0.1, accuracy: 1e-9)
        XCTAssertLessThan(PollCadence.tolerance(for: PollCadence.slow), PollCadence.slow / 2)
    }

    func testPeriodicGateUsesElapsedTimeNotPollCount() {
        var gate = PeriodicGate(period: 30)
        XCTAssertFalse(gate.due(now: 100))
        XCTAssertFalse(gate.due(now: 104))
        XCTAssertFalse(gate.due(now: 129.9))
        XCTAssertTrue(gate.due(now: 130))
        XCTAssertFalse(gate.due(now: 131))
        // 慢速档：轮询次数少，但时间一到照样触发。
        XCTAssertTrue(gate.due(now: 164))

        var first = PeriodicGate(period: 600)
        XCTAssertTrue(first.due(now: 5, fireFirst: true))
        XCTAssertFalse(first.due(now: 6, fireFirst: true))
        XCTAssertTrue(first.due(now: 605, fireFirst: true))
    }
}
