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

    static func processTable() -> ProcessTable {
        ProcessTable.parse(run("/bin/ps", ["-axo", "pid=,ppid=,tty=,comm="], timeout: 5) ?? "")
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
