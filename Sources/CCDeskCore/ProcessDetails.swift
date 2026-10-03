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
