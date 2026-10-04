import Foundation
import CCDeskCore

/// 一次顾问调用（设计 §14）：后台运行一次性的 `claude -p`（只读参数见 `ConsultCommand`），问题经 stdin 传入，
/// 逐行读 stream-json：工具调用数作为进度，最后的 result 行作为结果。子进程在自己的进程组里启动，
/// 超时 / 取消 / App 退出时先对整个组 SIGTERM，稍后 SIGKILL（claude 启动的 git 等子进程一并结束）。
/// 回调都在主线程，completion 恰好一次。
final class ConsultProcess: @unchecked Sendable {
    enum Ending {
        case finished(ConsultOutcome)
        case failed(String)
        case timedOut
        case cancelled
    }

    private let queue = DispatchQueue(label: "cc-desk.consult")
    private let executable: String
    private let searchPath: String?
    private let arguments: [String]
    private let cwd: URL
    private let input: String
    private let timeout: TimeInterval
    private let onProgress: (Int) -> Void
    private let completion: (Ending) -> Void

    // 以下只在 queue 上使用。
    /// 子进程 pid（= 它的进程组 id）；退出并回收后为 nil。
    private var pid: pid_t?
    /// 读输出的两端（要持有：FileHandle 释放时会关闭描述符）。
    private var outputs: [FileHandle] = []
    private var buffer = Data()
    private var stderrTail = Data()
    private var toolCalls = 0
    private var outcome: ConsultOutcome?
    private var ending: Ending?
    private var done = false

    init(executable: String, searchPath: String?, arguments: [String], cwd: URL, input: String,
         timeout: TimeInterval = ConsultCommand.timeout,
         onProgress: @escaping (Int) -> Void, completion: @escaping (Ending) -> Void) {
        self.executable = executable
        self.searchPath = searchPath
        self.arguments = arguments
        self.cwd = cwd
        self.input = input
        self.timeout = timeout
        self.onProgress = onProgress
        self.completion = completion
    }

    /// 子进程环境：去掉会话级 Claude Code 变量与控制接口口令（顾问不能用 CC Desk 的工具），
    /// 不限制扩展思考（让更强的模型自己决定想多久）；git 用安全设置（不执行仓库配置里的外部程序，见 `GitSafety`）。
    static func environment(searchPath: String?) -> [String: String] {
        var env = LaunchSpec.sanitizedEnvironment(base: ProcessInfo.processInfo.environment)
        if let searchPath { env["PATH"] = searchPath }
        env["MAX_THINKING_TOKENS"] = nil
        env["CC_DESK"] = "1"
        return GitSafety.environment(env)
    }

    @discardableResult
    func start() -> Bool {
        queue.sync {
            guard let child = SpawnedProcess.spawn(executable: executable, arguments: arguments,
                                                   environment: Self.environment(searchPath: searchPath), cwd: cwd) else {
                AssistantDiag.log("consult start failed: \(String(cString: strerror(errno)))")
                return false
            }
            pid = child.pid
            outputs = [child.stdout, child.stderr]
            child.stdout.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                self?.queue.async { self?.receive(data) }
            }
            child.stderr.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                self?.queue.async {
                    guard let self else { return }
                    self.stderrTail.append(data)
                    if self.stderrTail.count > 4096 { self.stderrTail = self.stderrTail.suffix(4096) }
                }
            }
            // 等进程退出（不回收，先清掉组里剩下的子进程），再回收并报告。
            let childPID = child.pid
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let status = SpawnedProcess.waitForExit(childPID)
                // 稍等让管道里剩下的输出读完（result 行可能和退出几乎同时到达）。
                self?.queue.asyncAfter(deadline: .now() + 0.2) { self?.exited(status) }
            }
            // 问题经 stdin 传入后关闭（claude -p 读到 EOF 才开始）。
            do {
                try child.stdin.write(contentsOf: Data(input.utf8))
            } catch {
                AssistantDiag.log("consult stdin write failed: \(error.localizedDescription)")
            }
            try? child.stdin.close()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.stop(.timedOut) }
            return true
        }
    }

    func cancel() {
        queue.async { [weak self] in self?.stop(.cancelled) }
    }

    /// App 退出时：同步结束整个进程组（SIGTERM，稍等后 SIGKILL），不等回调。
    func terminateNow() {
        let group: pid_t? = queue.sync {
            if !done, ending == nil { ending = .cancelled }
            return pid
        }
        guard let group else { return }
        killpg(group, SIGTERM)
        usleep(300_000)
        killpg(group, SIGKILL)
    }

    // MARK: 只在 queue 上调用

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let calls = ConsultOutcome.toolCalls(line: line)
            if calls > 0 {
                toolCalls += calls
                let count = toolCalls
                DispatchQueue.main.async { [onProgress] in onProgress(count) }
            }
            if line.contains("\"type\":\"result\""), let parsed = ConsultOutcome.parse(line: line) { outcome = parsed }
        }
    }

    /// 超时 / 取消：记下原因并结束整个进程组（claude 和它启动的 git 等）；3 秒后仍在就 SIGKILL。进程退出后在 exited 里报告。
    private func stop(_ reason: Ending) {
        guard !done, ending == nil, let group = pid else { return }
        ending = reason
        killpg(group, SIGTERM)
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            // 还没回收（pid 仍属于它）才发，避免误杀复用了这个 pid 的别的进程组。
            guard let self, self.pid == group else { return }
            killpg(group, SIGKILL)
        }
    }

    private func exited(_ status: Int32) {
        guard !done else { return }
        done = true
        pid = nil
        for handle in outputs { handle.readabilityHandler = nil }
        outputs = []
        let result: Ending
        if let ending {
            result = ending
        } else if let outcome, !outcome.isError, !outcome.answer.isEmpty {
            result = .finished(outcome)
        } else if let outcome {
            result = .failed(outcome.answer.isEmpty ? "the advisor returned an error" : String(outcome.answer.prefix(300)))
        } else {
            let err = String(data: stderrTail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result = .failed("exit \(status)" + (err.isEmpty ? "" : ": " + String(err.suffix(300))))
        }
        DispatchQueue.main.async { [completion] in completion(result) }
    }
}

/// posix_spawn 启动的子进程（Foundation 的 Process 不能让子进程进入新的进程组）：
/// 新进程组（pgid = pid）、只继承三个标准流、SIGPIPE 恢复默认（App 本身忽略它）。
struct SpawnedProcess {
    let pid: pid_t
    let stdin: FileHandle
    let stdout: FileHandle
    let stderr: FileHandle

    static func spawn(executable: String, arguments: [String], environment: [String: String], cwd: URL) -> SpawnedProcess? {
        var inFDs: [Int32] = [-1, -1], outFDs: [Int32] = [-1, -1], errFDs: [Int32] = [-1, -1]
        guard pipe(&inFDs) == 0 else { return nil }
        guard pipe(&outFDs) == 0 else { closeAll(inFDs); return nil }
        guard pipe(&errFDs) == 0 else { closeAll(inFDs + outFDs); return nil }
        // 父进程这边的描述符不能被同时启动的其他子进程继承（否则 stdin 永远等不到 EOF）；dup2 到 0/1/2 的副本不受影响。
        for fd in inFDs + outFDs + errFDs { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inFDs[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outFDs[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errFDs[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT：除了上面 dup2 的三个，App 打开的其他描述符都不进入子进程。
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        // 子进程那一端在父进程里关掉。
        close(inFDs[0])
        close(outFDs[1])
        close(errFDs[1])
        guard rc == 0 else {
            errno = rc
            closeAll([inFDs[1], outFDs[0], errFDs[0]])
            return nil
        }
        return SpawnedProcess(pid: pid,
                              stdin: FileHandle(fileDescriptor: inFDs[1], closeOnDealloc: true),
                              stdout: FileHandle(fileDescriptor: outFDs[0], closeOnDealloc: true),
                              stderr: FileHandle(fileDescriptor: errFDs[0], closeOnDealloc: true))
    }

    /// 阻塞等子进程退出：先不回收（pid 仍被占着，不会被复用）、清掉组里剩下的进程，再回收；返回退出码（被信号结束时 128+信号）。
    static func waitForExit(_ pid: pid_t) -> Int32 {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        killpg(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func closeAll(_ fds: [Int32]) {
        for fd in fds where fd >= 0 { close(fd) }
    }
}
