import Foundation
import CCDeskCore

enum SystemProbe {
    /// 执行命令，退出码为 0 时返回 stdout；超时或失败返回 nil。
    /// 并发读取 stdout 管道，避免管道缓冲区写满导致子进程阻塞，从而死锁在 waitUntilExit() 上。
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 3) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let dataBox = Locked<Data>(Data())
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { dataBox.withLock { $0.append(chunk) } }
        }

        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        let exited = Locked<Bool>(false)
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exited.withLock { $0 = true }
            semaphore.signal()
        }

        let deadline = DispatchTime.now() + timeout
        if semaphore.wait(timeout: deadline) == .timedOut {
            process.terminationHandler = nil
            process.terminate()
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        // 读完 readabilityHandler 已排空的数据后，再补读一次管道中剩余的尾部字节。
        let remaining = pipe.fileHandleForReading.availableData
        if !remaining.isEmpty { dataBox.withLock { $0.append(remaining) } }

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

/// 简单的互斥锁包装，供后台回调（readabilityHandler/terminationHandler）与等待线程之间安全共享状态。
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
