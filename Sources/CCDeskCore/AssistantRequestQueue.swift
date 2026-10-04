import Foundation

/// 常驻助手会话的请求队列状态机（设计 §12）：一次只有一条请求在等回复，其余排队。
///
/// 保证：
/// - 每条请求的 completion **恰好调用一次**（回复、失败、超时、进程退出、重置、关闭都算）；
/// - 任何一条请求结束后队列继续往下走（不会因为超时 / 重置 / 写失败而卡住）。
///
/// 不碰进程与线程：启动 / 写入 / 停止进程与定时都由 `Driver` 提供，调用方只在自己的串行队列上使用（非线程安全）。
public final class AssistantRequestQueue<Reply> {
    public enum Failure: Error, Equatable, Sendable {
        /// 无法启动进程（如找不到 claude）。
        case notStarted
        case timeout
        /// 写入进程 stdin 失败。
        case writeFailed
        /// 进程在回复前退出。
        case exited
        /// 被重置 / 轮换 / 关闭等原因中止。
        case aborted(String)
        /// 进程返回了错误结果。
        case failed(String)
    }

    public typealias Completion = (Result<Reply, Failure>) -> Void

    public struct Driver {
        /// 进程没在运行时启动它；返回 false 表示无法启动。
        public var ensureRunning: () -> Bool
        /// 把一条消息写给进程；返回 false 表示写失败。
        public var send: (String) -> Bool
        /// 停止进程（之后不再把它的退出报告给队列）。
        public var stopProcess: () -> Void
        /// `seconds` 秒后在同一串行队列上执行。
        public var schedule: (TimeInterval, @escaping () -> Void) -> Void

        public init(ensureRunning: @escaping () -> Bool, send: @escaping (String) -> Bool,
                    stopProcess: @escaping () -> Void, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
            self.ensureRunning = ensureRunning
            self.send = send
            self.stopProcess = stopProcess
            self.schedule = schedule
        }
    }

    private struct Pending {
        let message: String
        let turn: AssistantTurn?
        let timeout: TimeInterval
        let completion: Completion
    }

    private var driver: Driver
    private var pending: [Pending] = []
    private var current: (completion: Completion, started: Date, token: Int, turn: AssistantTurn?)?
    private var token = 0
    private let now: () -> Date

    public init(driver: Driver, now: @escaping () -> Date = Date.init) {
        self.driver = driver
        self.now = now
    }

    /// 有请求在等回复。
    public var isBusy: Bool { current != nil }
    public var pendingCount: Int { pending.count }
    /// 当前请求的开始时间（算延迟用）。
    public var currentStartedAt: Date? { current?.started }
    /// 当前请求的种类（工具调用权限据此判断，见 `AssistantToolPolicy`）；没有请求在等回复时 nil。
    public var currentTurn: AssistantTurn? { current?.turn }

    /// turn：这条请求的种类；不给时按最严格的处理（会改变东西的工具一律拒绝）。
    public func enqueue(_ message: String, turn: AssistantTurn? = nil, timeout: TimeInterval,
                        completion: @escaping Completion) {
        pending.append(Pending(message: message, turn: turn, timeout: timeout, completion: completion))
        pump()
    }

    /// 当前请求有了结果；restart：之后停掉进程（如上下文过大要换新会话），下一条请求重新启动。
    public func complete(_ result: Result<Reply, Failure>, restart: Bool = false) {
        guard let current else { return }
        self.current = nil
        current.completion(result)
        if restart { driver.stopProcess() }
        pump()
    }

    /// 进程自己退出了（调用方已确认是当前进程）：当前请求失败，后面的请求会重新启动进程。
    public func processExited() {
        failCurrent(.exited)
        pump()
    }

    /// 停掉进程并让当前请求失败；排队的请求继续（用新进程）。
    public func abort(_ reason: String) {
        failCurrent(.aborted(reason))
        driver.stopProcess()
        pump()
    }

    /// 关闭：停掉进程，当前与排队的请求全部失败。
    public func shutdown() {
        failCurrent(.aborted("shutdown"))
        driver.stopProcess()
        let dropped = pending
        pending = []
        dropped.forEach { $0.completion(.failure(.aborted("shutdown"))) }
    }

    // MARK: 内部

    private func failCurrent(_ failure: Failure) {
        guard let current else { return }
        self.current = nil
        current.completion(.failure(failure))
    }

    private func pump() {
        // 写失败时这一条失败、继续下一条：每轮至少消耗一条请求，不会死循环。
        while current == nil, !pending.isEmpty {
            guard driver.ensureRunning() else {
                let failed = pending
                pending = []
                failed.forEach { $0.completion(.failure(.notStarted)) }
                return
            }
            let next = pending.removeFirst()
            token += 1
            let mine = token
            current = (next.completion, now(), mine, next.turn)
            guard driver.send(next.message) else {
                driver.stopProcess()
                failCurrent(.writeFailed)
                continue
            }
            driver.schedule(next.timeout) { [weak self] in
                guard let self, let current = self.current, current.token == mine else { return }
                self.failCurrent(.timeout)
                self.driver.stopProcess()
                self.pump()
            }
        }
    }
}
