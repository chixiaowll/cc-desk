import Foundation
import CCDeskCore

enum SystemProbe {
    /// 执行命令，退出码为 0 时返回 stdout；超时或失败返回 nil。
    /// 后台线程阻塞读取整个 stdout；主调用方等待该读取完成或超时。超时后 terminate() 会关闭子进程的
    /// 标准输出写端，使后台读取收到 EOF 并退出，避免遗留一个永久阻塞的读线程。
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 3) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        let dataBox = Locked<Data>(Data())
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            dataBox.withLock { $0 = data }
            done.signal()
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: dataBox.withLock { $0 }, encoding: .utf8)
    }

    /// 进程表：原生接口（`NativeProcessReader`，约 1 ms，不起子进程）；系统调用失败时退回 ps。
    static func processTable() -> ProcessTable {
        NativeProcessReader.shared.table() ?? psProcessTable()
    }

    /// 用 `/bin/ps` 构建的进程表（约 100 ms，两次子进程）：原生接口失败时兜底，`--proc-selftest` 用来对照。
    /// comm 必须在行尾（路径可能含空格），命令行另用一次 `ps -axo pid=,args=` 取得并按 pid 合并。
    static func psProcessTable() -> ProcessTable {
        let comm = run("/bin/ps", ["-axo", "pid=,ppid=,tty=,comm="], timeout: 5) ?? ""
        let args = run("/bin/ps", ["-axo", "pid=,args="], timeout: 5)
        return ProcessTable.parse(comm, args: args)
    }

    /// 在用户的登录交互 shell 里检测 codex / pi 是否安装（GUI App 的 PATH 不含用户目录，不能直接 which）。
    /// 阻塞最多约 3 秒，只在后台队列调用；失败或超时返回空集合。
    static func installedAgents() -> Set<AgentKind> {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return AgentProbe.parse(run(shell, ["-l", "-i", "-c", AgentProbe.script], timeout: 3) ?? "")
    }

    static func processDetails(pid: Int32, includeCwd: Bool) -> ProcessDetails? {
        ProcessDetails.of(pid: pid, includeCwd: includeCwd)
    }

    static func git(cwd: String, args: [String]) -> String? {
        run("/usr/bin/git", ["-C", cwd] + args, timeout: 3)
    }
}

/// 简单的互斥锁包装，供后台读取线程与等待线程之间安全共享数据。
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
