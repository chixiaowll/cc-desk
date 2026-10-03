import Foundation

/// 单实例锁（设计 §4.8）：`flock(LOCK_EX)` 锁住 `~/.cc-desk/instance.lock`，App 运行期间一直持有。
/// 第二个界面实例拿不到锁，就去激活已在运行的实例然后退出；`--mcp`、`--tts-test`、`--tmux-selftest` 不拿锁。
/// fd 带 O_CLOEXEC：内嵌终端、tmux 服务器等子进程不会继承它（否则 App 退出后锁仍被子进程占着）。
/// 进程退出（含崩溃）时内核自动释放锁。
public final class InstanceLock {
    public static let environmentKey = "CCDESK_INSTANCE_LOCK"

    public let path: String
    private var fd: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    /// 锁文件路径：环境变量 `CCDESK_INSTANCE_LOCK` 优先（测试 / 隔离运行用），否则 `~/.cc-desk/instance.lock`。
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   home: String = NSHomeDirectory()) -> String {
        if let path = environment[environmentKey], !path.isEmpty { return path }
        return (home as NSString).appendingPathComponent(".cc-desk/instance.lock")
    }

    public var isHeld: Bool { fd >= 0 }

    /// 不等待地尝试加锁；已持有时返回 true。
    public func tryAcquire() -> Bool {
        if fd >= 0 { return true }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let opened = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard opened >= 0 else { return false }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            close(opened)
            return false
        }
        fd = opened
        // 记下持有者的 pid，便于诊断（内容不参与加锁）。
        let text = "\(getpid())\n"
        _ = ftruncate(opened, 0)
        _ = text.withCString { pwrite(opened, $0, strlen($0), 0) }
        return true
    }

    /// 最多等 `timeout` 秒（每 `interval` 秒重试一次），用于重启时等待旧实例退出。
    public func acquire(timeout: TimeInterval, interval: TimeInterval = 0.1) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if tryAcquire() { return true }
            guard Date() < deadline else { return false }
            usleep(useconds_t(max(interval, 0.01) * 1_000_000))
        }
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
