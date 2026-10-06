import Foundation

/// 轮询节奏（设计 §26.2）：用户看着 CC Desk 时每秒一次；App 不在前台、窗口都不可见（关闭 / 最小化 / 被完全遮住）、
/// 屏幕锁定或显示器睡眠时放慢到 `slow`。hook 状态 / Claude 注册表文件一变就立即补一次（与上次至少隔 `minGap`），
/// 所以状态变化与通知不随慢速档延迟；只有纯进程表上的变化（新开的外部会话、进程退出）最多晚 `slow` 秒。
public struct PollConditions: Equatable, Sendable {
    public var appActive: Bool
    /// 有主窗口 / 独立终端窗口可见且没被完全遮住。
    public var windowVisible: Bool
    public var screenLocked: Bool
    /// 显示器或系统睡眠。
    public var displayAsleep: Bool

    public init(appActive: Bool, windowVisible: Bool, screenLocked: Bool = false, displayAsleep: Bool = false) {
        self.appActive = appActive
        self.windowVisible = windowVisible
        self.screenLocked = screenLocked
        self.displayAsleep = displayAsleep
    }
}

public enum PollCadence {
    public static let fast: TimeInterval = 1
    public static let slow: TimeInterval = 4
    /// 文件变化 / 回到前台触发的立即轮询，与上一次轮询开始至少隔这么久（连续的 hook 写入合并成一次）。
    public static let minGap: TimeInterval = 0.3

    public static func interval(_ c: PollConditions) -> TimeInterval {
        let watched = c.appActive && c.windowVisible && !c.screenLocked && !c.displayAsleep
        return watched ? fast : slow
    }

    /// 上一次轮询开始 `elapsed` 秒后，下一次还要等多久。`changed`：期间有状态文件变化或刚回到前台，要尽快补一次。
    public static func delay(elapsed: TimeInterval, interval: TimeInterval, changed: Bool) -> TimeInterval {
        max(0, (changed ? min(minGap, interval) : interval) - max(0, elapsed))
    }

    /// 定时器的容差：让系统把唤醒和别的定时器合并（约为间隔的 1/10）。
    public static func tolerance(for interval: TimeInterval) -> TimeInterval {
        interval / 10
    }
}

/// 按真实经过的时间（而不是轮询次数）触发的低频任务：轮询变慢后，「每 30 秒」仍是 30 秒。
public struct PeriodicGate: Equatable, Sendable {
    public let period: TimeInterval
    public private(set) var last: TimeInterval?

    public init(period: TimeInterval) {
        self.period = period
    }

    /// `now` 为单调时钟（如 systemUptime）。第一次调用返回 `fireFirst`，之后每过 `period` 返回一次 true。
    public mutating func due(now: TimeInterval, fireFirst: Bool = false) -> Bool {
        guard let last else {
            self.last = now
            return fireFirst
        }
        guard now - last >= period else { return false }
        self.last = now
        return true
    }
}
