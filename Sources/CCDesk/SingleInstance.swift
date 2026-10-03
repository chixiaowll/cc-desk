import AppKit
import CCDeskCore

/// 单实例（设计 §4.8）：界面实例启动时拿 `~/.cc-desk/instance.lock`，运行期间一直持有。
/// 拿不到锁说明已有实例在运行：激活它然后退出，避免两个实例互相覆盖 workspace.json、争抢控制接口与 tmux 会话。
/// `--mcp` / `--tts-test` / `--tmux-selftest` 与本地化探针在这之前就已退出或不经过这里，不拿锁。
enum SingleInstance {
    /// 切换语言重启时新实例带上这个参数：旧实例可能还没完全退出，先等一会儿锁。
    static let relaunchArgument = "--relaunched"
    static let relaunchWait: TimeInterval = 15

    private static let lock = InstanceLock(path: InstanceLock.defaultPath())

    /// 在 main() 里、启动界面之前调用；拿不到锁时不返回。
    static func acquireOrHandOff() {
        if ProcessInfo.processInfo.environment["CCDESK_L10N_PROBE"] == "1" { return }
        let relaunched = CommandLine.arguments.dropFirst().contains(relaunchArgument)
        if lock.acquire(timeout: relaunched ? relaunchWait : 0) { return }
        let others = Bundle.main.bundleIdentifier.map { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != getpid() }
        } ?? []
        if let existing = others.first {
            FileHandle.standardError.write(Data("CC Desk is already running (pid \(existing.processIdentifier)); activating it.\n".utf8))
            existing.unhide()
            existing.activate(options: [.activateAllWindows])
        } else {
            FileHandle.standardError.write(Data("Another CC Desk holds \(lock.path); exiting.\n".utf8))
        }
        exit(0)
    }

    /// 重启前交出锁，让新实例立即拿到。
    static func release() {
        lock.release()
    }

    /// 重启失败时拿回锁。
    @discardableResult
    static func reacquire() -> Bool {
        lock.tryAcquire()
    }
}
