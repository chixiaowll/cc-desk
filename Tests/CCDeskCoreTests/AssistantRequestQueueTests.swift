import XCTest
@testable import CCDeskCore

/// 助手请求队列：超时 / 重置 / 进程退出 / 轮换 / 写失败时，每条请求的 completion 恰好一次，队列继续往下走。
final class AssistantRequestQueueTests: XCTestCase {
    /// 假进程 + 手动时钟。
    private final class Fake {
        var running = false
        var canStart = true
        var failWrites = 0
        var starts = 0
        var stops = 0
        var sent: [String] = []
        var timers: [(at: TimeInterval, work: () -> Void)] = []
        var clock: TimeInterval = 0

        lazy var queue = AssistantRequestQueue<String>(driver: AssistantRequestQueue.Driver(
            ensureRunning: { [unowned self] in
                if running { return true }
                guard canStart else { return false }
                running = true
                starts += 1
                return true
            },
            send: { [unowned self] message in
                if failWrites > 0 { failWrites -= 1; return false }
                sent.append(message)
                return true
            },
            stopProcess: { [unowned self] in
                if running { stops += 1 }
                running = false
            },
            schedule: { [unowned self] seconds, work in timers.append((clock + seconds, work)) }))

        func advance(_ seconds: TimeInterval) {
            clock += seconds
            let due = timers.filter { $0.at <= clock }
            timers.removeAll { $0.at <= clock }
            due.forEach { $0.work() }
        }
    }

    private final class Results {
        var values: [String: [Result<String, AssistantRequestQueue<String>.Failure>]] = [:]
        func sink(_ key: String) -> (Result<String, AssistantRequestQueue<String>.Failure>) -> Void {
            { [unowned self] in values[key, default: []].append($0) }
        }
        func once(_ key: String) -> Result<String, AssistantRequestQueue<String>.Failure>? {
            guard let list = values[key] else { return nil }
            XCTAssertEqual(list.count, 1, "\(key) completed \(list.count) times")
            return list.first
        }
    }

    func testRepliesInOrder() {
        let fake = Fake(), results = Results()
        fake.queue.enqueue("a", timeout: 10, completion: results.sink("a"))
        fake.queue.enqueue("b", timeout: 10, completion: results.sink("b"))
        XCTAssertEqual(fake.sent, ["a"], "only one request in flight")
        fake.queue.complete(.success("A"))
        XCTAssertEqual(fake.sent, ["a", "b"])
        fake.queue.complete(.success("B"))
        XCTAssertEqual(results.once("a"), .success("A"))
        XCTAssertEqual(results.once("b"), .success("B"))
        XCTAssertFalse(fake.queue.isBusy)
        XCTAssertEqual(fake.starts, 1)
    }

    func testTimeoutFailsOnceAndQueueKeepsMoving() {
        let fake = Fake(), results = Results()
        fake.queue.enqueue("a", timeout: 5, completion: results.sink("a"))
        fake.queue.enqueue("b", timeout: 5, completion: results.sink("b"))
        fake.advance(6)
        XCTAssertEqual(results.once("a"), .failure(.timeout))
        XCTAssertEqual(fake.stops, 1, "the hung process is stopped")
        XCTAssertEqual(fake.sent, ["a", "b"], "the next request goes out on a new process")
        XCTAssertEqual(fake.starts, 2)
        // 迟到的回复属于 b（a 已超时），a 不会再被调用。
        fake.queue.complete(.success("B"))
        XCTAssertEqual(results.once("b"), .success("B"))
        fake.advance(10)
        XCTAssertEqual(results.values["a"]?.count, 1)
        XCTAssertEqual(results.values["b"]?.count, 1, "an answered request's timer does nothing")
    }

    func testAbortWithPendingRequests() {
        let fake = Fake(), results = Results()
        fake.queue.enqueue("a", timeout: 5, completion: results.sink("a"))
        fake.queue.enqueue("b", timeout: 5, completion: results.sink("b"))
        fake.queue.abort("reset")
        XCTAssertEqual(results.once("a"), .failure(.aborted("reset")))
        XCTAssertEqual(fake.sent, ["a", "b"])
        XCTAssertTrue(fake.queue.isBusy)
        fake.advance(6)
        XCTAssertEqual(results.once("b"), .failure(.timeout))
        XCTAssertFalse(fake.queue.isBusy)
        // 空闲时重置不会调用任何 completion。
        fake.queue.abort("reset")
        XCTAssertEqual(results.values.values.map(\.count).reduce(0, +), 2)
    }

    func testProcessExitFailsCurrentAndRestartsForNext() {
        let fake = Fake(), results = Results()
        fake.queue.enqueue("a", timeout: 5, completion: results.sink("a"))
        fake.queue.enqueue("b", timeout: 5, completion: results.sink("b"))
        fake.running = false
        fake.queue.processExited()
        XCTAssertEqual(results.once("a"), .failure(.exited))
        XCTAssertEqual(fake.starts, 2)
        XCTAssertEqual(fake.sent, ["a", "b"])
        // 空闲时进程退出：没有请求要失败。
        fake.queue.complete(.success("B"))
        fake.queue.processExited()
        XCTAssertEqual(results.once("b"), .success("B"))
    }

    func testRotationRestartsAfterReply() {
        let fake = Fake(), results = Results()
        fake.queue.enqueue("a", timeout: 5, completion: results.sink("a"))
        fake.queue.enqueue("b", timeout: 5, completion: results.sink("b"))
        fake.queue.complete(.success("A"), restart: true)
        XCTAssertEqual(results.once("a"), .success("A"))
        XCTAssertEqual(fake.stops, 1)
        XCTAssertEqual(fake.starts, 2, "b runs on a fresh process")
        XCTAssertEqual(fake.sent, ["a", "b"])
    }

    func testWriteFailureMovesOn() {
        let fake = Fake(), results = Results()
        fake.failWrites = 1
        fake.queue.enqueue("a", timeout: 5, completion: results.sink("a"))
        XCTAssertEqual(results.once("a"), .failure(.writeFailed))
        XCTAssertFalse(fake.queue.isBusy)
        fake.queue.enqueue("b", timeout: 5, completion: results.sink("b"))
        XCTAssertEqual(fake.sent, ["b"])
        fake.queue.complete(.success("B"))
        XCTAssertEqual(results.once("b"), .success("B"))
    }

    func testCannotStartFailsEverythingPending() {
        let fake = Fake(), results = Results()
        fake.canStart = false
        fake.queue.enqueue("a", timeout: 5, completion: results.sink("a"))
        XCTAssertEqual(results.once("a"), .failure(.notStarted))
        fake.canStart = true
        fake.queue.enqueue("b", timeout: 5, completion: results.sink("b"))
        XCTAssertEqual(fake.sent, ["b"])
    }

    func testShutdownFailsCurrentAndPending() {
        let fake = Fake(), results = Results()
        fake.queue.enqueue("a", timeout: 5, completion: results.sink("a"))
        fake.queue.enqueue("b", timeout: 5, completion: results.sink("b"))
        fake.queue.shutdown()
        XCTAssertEqual(results.once("a"), .failure(.aborted("shutdown")))
        XCTAssertEqual(results.once("b"), .failure(.aborted("shutdown")))
        fake.advance(10)
        XCTAssertEqual(results.values["a"]?.count, 1)
    }

    func testCompletionThatEnqueuesDoesNotDoubleSend() {
        let fake = Fake(), results = Results()
        fake.queue.enqueue("a", timeout: 5) { result in
            results.sink("a")(result)
            fake.queue.enqueue("c", timeout: 5, completion: results.sink("c"))
        }
        fake.queue.enqueue("b", timeout: 5, completion: results.sink("b"))
        fake.queue.complete(.success("A"))
        XCTAssertEqual(fake.sent, ["a", "b"])
        fake.queue.complete(.success("B"))
        fake.queue.complete(.success("C"))
        XCTAssertEqual(fake.sent, ["a", "b", "c"])
        XCTAssertEqual(results.once("c"), .success("C"))
    }
}
