import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 内核进程表里的一条（`sysctl(KERN_PROC_ALL)`，一次系统调用拿到全部进程，不需要特权，其他用户的进程也在）。
public struct KernelProcess: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let pgid: Int32
    public let uid: UInt32
    /// 控制终端设备号；没有终端时为 nil。
    public let tty: Int32?
    public let key: ProcessCommandKey
    public let isZombie: Bool

    public init(pid: Int32, ppid: Int32, pgid: Int32, uid: UInt32, tty: Int32?, key: ProcessCommandKey, isZombie: Bool) {
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid
        self.uid = uid
        self.tty = tty
        self.key = key
        self.isZombie = isZombie
    }
}

/// 用原生接口构建 `ProcessTable`，代替每秒两次的 `/bin/ps`（各约 50 ms 的子进程）。输出与 `ps` 一致：
/// - pid / ppid / tty：`KERN_PROC_ALL`（tty 用 `devname(e_tdev, S_IFCHR)`，如 "ttys007"）；
/// - comm / args：本用户的进程读 `KERN_PROCARGS2`（argv[0] 与完整命令行，与 ps 一样），按 `ProcessCommandKey`
///   缓存，只有新进程、exec 过的进程和刚启动 `settleAge` 内的进程才重读；
/// - 其他用户的进程读不到命令行（EPERM，ps 是 setuid root 才能读）：comm 退回 `proc_pidpath` / 内核短名，args 为 nil。
///   使用方只看本用户进程的命令行（agent 识别）和宿主 App 的路径，不受影响。
/// 线程安全（内部加锁）；`devname` 不可重入，也在锁内调用。
public final class NativeProcessReader: @unchecked Sendable {
    public static let shared = NativeProcessReader()

    private struct Cached {
        let key: ProcessCommandKey
        let command: String
        let args: String?
    }

    private let lock = NSLock()
    private var cache: [Int32: Cached] = [:]
    private var ttyNames: [Int32: String] = [:]
    private var argsBuffer: [UInt8] = []
    private let ownUID = getuid()

    public init() {}

    /// 当前的进程表；系统调用失败时返回 nil（调用方可退回 ps）。
    public func table(now: Date = Date()) -> ProcessTable? {
        #if canImport(Darwin)
        guard let procs = Self.kernelProcesses() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var byPID: [Int32: ProcInfo] = [:]
        byPID.reserveCapacity(procs.count)
        var fresh: [Int32: Cached] = [:]
        fresh.reserveCapacity(procs.count)
        // pid 0（kernel_task）ps -ax 不列出，保持一致。
        for p in procs where p.pid != 0 {
            let entry = command(for: p, now: now)
            fresh[p.pid] = entry
            byPID[p.pid] = ProcInfo(pid: p.pid, ppid: p.ppid, tty: p.tty.map(ttyName), command: entry.command, args: entry.args)
        }
        // 只保留仍存在的进程，缓存不随时间增长。
        cache = fresh
        return ProcessTable(byPID: byPID)
        #else
        return nil
        #endif
    }

    /// 与 `pid` 同一控制终端上的所有进程组（升序）；`pid` 没有终端或不存在时为空。
    public func processGroups(onTTYOf pid: Int32) -> [Int32] {
        guard let procs = Self.kernelProcesses(),
              let tty = procs.first(where: { $0.pid == pid })?.tty else { return [] }
        return Set(procs.filter { $0.tty == tty }.map(\.pgid)).sorted()
    }

    /// 某个进程的控制终端名（如 "ttys007"）；没有终端或不存在时 nil。
    public func ttyName(ofPID pid: Int32) -> String? {
        guard let tty = Self.kernelProcesses()?.first(where: { $0.pid == pid })?.tty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return ttyName(tty)
    }

    // MARK: 内部

    private func command(for p: KernelProcess, now: Date) -> Cached {
        if let cached = cache[p.pid], !p.key.needsRefresh(cached: cached.key, now: now) { return cached }
        if p.isZombie { return Cached(key: p.key, command: "<defunct>", args: "<defunct>") }
        if p.uid == ownUID, let parsed = procArgs(pid: p.pid), let command = parsed.command {
            return Cached(key: p.key, command: command, args: parsed.args)
        }
        let command = Self.executablePath(pid: p.pid) ?? p.key.shortName
        return Cached(key: p.key, command: command, args: nil)
    }

    /// 只在持锁时调用（devname 返回静态缓冲区）。
    private func ttyName(_ dev: Int32) -> String {
        if let name = ttyNames[dev] { return name }
        #if canImport(Darwin)
        let name = devname(dev_t(dev), S_IFCHR).map { String(cString: $0) } ?? "?"
        #else
        let name = "?"
        #endif
        ttyNames[dev] = name
        return name
    }

    /// `sysctl(KERN_PROC_ALL)`；进程数在两次调用之间变多时重试。
    public static func kernelProcesses() -> [KernelProcess]? {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            size += size / 8 + stride * 16
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
            let result = buffer.withUnsafeMutableBytes { raw in
                sysctl(&mib, UInt32(mib.count), raw.baseAddress, &size, nil, 0)
            }
            if result != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            let count = size / stride
            return buffer.prefix(count).map(KernelProcess.init(kinfo:))
        }
        return nil
        #else
        return nil
        #endif
    }

    private static let argMax: Int = {
        #if canImport(Darwin)
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        if sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 { return Int(value) }
        #endif
        return 1 << 20
    }()

    /// 读 `KERN_PROCARGS2` 并解析；其他用户的进程（EPERM）或已退出的进程返回 nil。
    /// 复用同一块 ARG_MAX 大小的缓冲区（每次新分配 1 MB 并清零比系统调用本身还贵），只在持锁时调用。
    private func procArgs(pid: Int32) -> ProcArgs.Parsed? {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        if argsBuffer.count < Self.argMax { argsBuffer = [UInt8](repeating: 0, count: Self.argMax) }
        var size = argsBuffer.count
        let result = argsBuffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        return ProcArgs.parse(Array(argsBuffer.prefix(size)))
        #else
        return nil
        #endif
    }

    private static func executablePath(pid: Int32) -> String? {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
        #else
        return nil
        #endif
    }
}

#if canImport(Darwin)
extension KernelProcess {
    init(kinfo k: kinfo_proc) {
        let start = k.kp_proc.p_un.__p_starttime
        let shortName = withUnsafeBytes(of: k.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let tdev = k.kp_eproc.e_tdev
        self.init(pid: k.kp_proc.p_pid, ppid: k.kp_eproc.e_ppid, pgid: k.kp_eproc.e_pgid,
                  uid: k.kp_eproc.e_ucred.cr_uid, tty: tdev == -1 ? nil : tdev,
                  key: ProcessCommandKey(startSec: Int(start.tv_sec), startUsec: Int(start.tv_usec), shortName: shortName),
                  isZombie: k.kp_proc.p_stat == SZOMB)
    }
}
#endif
