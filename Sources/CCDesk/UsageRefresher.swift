import Foundation
import CCDeskCore

/// 让 Claude Code 重新拉取订阅用量。Claude Code 只在执行 `/usage` 时更新 ~/.claude.json 里的用量缓存，
/// 所以这里在后台执行（定时 / 有会话完成一轮 / 打开用量详情时） `claude -p "/usage"`（本地命令，不调用模型、不占额度，实测约 3 秒），完成后再读缓存。
/// 工作目录用助手目录（~/.cc-desk/assistant），不产生会话记录。
final class UsageRefresher {
    enum Reason {
        /// 定时：缓存超过 5 分钟。
        case periodic
        /// 有会话完成一轮（用量变化最大的时候）。
        case taskFinished
        /// 打开用量详情。
        case opened

        /// 缓存超过这个时间才刷新；同类原因两次刷新之间也至少隔这么久。
        var interval: TimeInterval {
            switch self {
            case .periodic: return 5 * 60
            case .taskFinished: return 30
            case .opened: return 20
            }
        }
    }

    private let queue = DispatchQueue(label: "cc-desk.usage.refresh")
    private var running = false
    private var lastRun: Date?

    /// fetchedAt：当前缓存的拉取时间（nil = 没有缓存）。completion 在主线程，只在真正执行过刷新后调用。只在主线程调用。
    func refresh(fetchedAt: Date?, reason: Reason, now: Date = Date(), completion: @escaping () -> Void) {
        let interval = reason.interval
        guard !running else { return }
        if let fetchedAt, now.timeIntervalSince(fetchedAt) < interval { return }
        if let lastRun, now.timeIntervalSince(lastRun) < interval { return }
        running = true
        lastRun = now
        queue.async { [weak self] in
            let ok = Self.run()
            DispatchQueue.main.async {
                self?.running = false
                if ok { completion() }
            }
        }
    }

    private static func run() -> Bool {
        guard let exe = AssistantClient.shared.resolvedClaude() else { return false }
        let dir = AssistantClient.workingDirectory
        AssistantClient.prepareWorkingDirectory(dir)
        var env = LaunchSpec.sanitizedEnvironment(base: ProcessInfo.processInfo.environment)
        if let path = exe.searchPath { env["PATH"] = path }
        env["CC_DESK"] = "1"
        let args = ["-p", "/usage", "--no-session-persistence", "--strict-mcp-config", "--tools", ""]
        switch ProcessRunner.run(exe.path, args, environment: env, cwd: dir, timeout: 30) {
        case .finished:
            return true
        case .failed(let message):
            AssistantDiag.log("usage refresh failed: \(message)")
            return false
        case .timedOut:
            AssistantDiag.log("usage refresh timed out")
            return false
        }
    }
}
