import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 进程启动时间与 cwd。
public struct ProcessDetails: Equatable, Sendable {
    public let startedAt: Date
    public let cwd: String?

    public init(startedAt: Date, cwd: String?) {
        self.startedAt = startedAt
        self.cwd = cwd
    }

    /// 用 libproc 读取（同一用户的进程无需特权、不起子进程）；进程不存在时返回 nil。
    public static func of(pid: Int32, includeCwd: Bool) -> ProcessDetails? {
        #if canImport(Darwin)
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { return nil }
        let start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
        guard includeCwd else { return ProcessDetails(startedAt: start, cwd: nil) }
        var vnode = proc_vnodepathinfo()
        let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        var cwd: String?
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, vnodeSize) == vnodeSize {
            cwd = withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { raw in
                raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) }
            }
            if cwd?.isEmpty == true { cwd = nil }
        }
        return ProcessDetails(startedAt: start, cwd: cwd)
        #else
        return nil
        #endif
    }
}

/// 进程身份：pid + 启动时间 + 可执行文件名。pid 会被复用，所以在弹窗确认之后真正发信号之前要复核：
/// 同一个 pid 的启动时间或名字变了，就不是当初那个进程。
public struct ProcessIdentity: Equatable, Sendable {
    public let pid: Int32
    public let startedAt: Date
    public let name: String

    public init(pid: Int32, startedAt: Date, name: String) {
        self.pid = pid
        self.startedAt = startedAt
        self.name = name
    }

    /// 读取当前运行中的进程身份；进程不存在时返回 nil。
    public static func current(pid: Int32) -> ProcessIdentity? {
        #if canImport(Darwin)
        guard pid > 0, let details = ProcessDetails.of(pid: pid, includeCwd: false) else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        let name = length > 0 ? String(cString: buffer) : ""
        return ProcessIdentity(pid: pid, startedAt: details.startedAt, name: name)
        #else
        return nil
        #endif
    }

    /// `now` 仍是同一个进程（启动时间精确到秒级以内相同，名字相同）。
    public func matches(_ now: ProcessIdentity?) -> Bool {
        guard let now, now.pid == pid else { return false }
        return abs(now.startedAt.timeIntervalSince(startedAt)) < 0.001 && now.name == name
    }
}
