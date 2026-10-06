import Foundation
import CCDeskCore

/// `CCDesk --proc-selftest`：不启动界面，在本机实时进程上对照原生进程表（`NativeProcessReader`）与 `/bin/ps`：
/// 两边都看到、两次原生快照之间没变的进程，pid → ppid / tty 必须完全一致；本用户进程的 comm 与 args 必须一致
/// （其他用户的进程 ps 以 setuid root 读命令行，原生只能退回可执行文件路径，只统计不判失败）；
/// agent 识别（Codex / pi）与 tty 上的进程组也要一致。并打印两种方式的耗时。只读，不连接正在运行的 CC Desk。
enum ProcSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.dropFirst().contains("--proc-selftest") else { return }
        exit(run() ? 0 : 1)
    }

    static func run() -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            print((condition ? "PASS " : "FAIL ") + message)
            if !condition { ok = false }
        }

        let reader = NativeProcessReader()
        guard let before = NativeProcessReader.kernelProcesses(), let native = reader.table() else {
            check(false, "sysctl(KERN_PROC_ALL) available")
            return false
        }
        let ps = SystemProbe.psProcessTable()
        guard let after = NativeProcessReader.kernelProcesses() else { return false }
        let keyAfter = Dictionary(after.map { ($0.pid, $0.key) }, uniquingKeysWith: { a, _ in a })
        let uid = getuid()
        // 两次原生快照之间身份没变的进程（排除 ps 期间新起 / 退出 / exec 的）。
        let stable = before.filter { $0.pid != 0 && keyAfter[$0.pid] == $0.key && !$0.isZombie }
        let psOnly = Set(ps.byPID.keys).subtracting(before.map(\.pid)).subtracting(after.map(\.pid))
        let missing = stable.filter { ps.byPID[$0.pid] == nil }
        print("processes: native \(native.byPID.count), ps \(ps.byPID.count), stable \(stable.count), " +
              "own-user \(stable.filter { $0.uid == uid }.count)")
        check(missing.isEmpty, "every stable native pid is in ps (missing: \(missing.prefix(5).map(\.pid)))")
        // ps 自己和两次 ps 之间的短命进程只出现在 ps 一侧；允许少量。
        check(psOnly.count <= 5, "pids only ps saw: \(psOnly.count) \(psOnly.sorted().prefix(5))")

        var ppidDiff: [Int32] = [], ttyDiff: [Int32] = [], ownCommDiff: [Int32] = [], ownArgsDiff: [Int32] = []
        var otherComm = (same: 0, sameName: 0, differ: 0)
        for p in stable {
            guard let n = native.byPID[p.pid], let q = ps.byPID[p.pid] else { continue }
            if n.ppid != q.ppid { ppidDiff.append(p.pid) }
            if n.tty != q.tty { ttyDiff.append(p.pid) }
            if p.uid == uid {
                if n.command != q.command { ownCommDiff.append(p.pid) }
                if n.args != q.args { ownArgsDiff.append(p.pid) }
            } else if n.command == q.command {
                otherComm.same += 1
            } else if n.executableName == q.executableName {
                otherComm.sameName += 1
            } else {
                otherComm.differ += 1
            }
        }
        func show(_ pids: [Int32], _ field: (ProcInfo) -> String?) -> String {
            pids.prefix(3).map { pid in
                "\(pid): native=\(native.byPID[pid].flatMap(field) ?? "nil") ps=\(ps.byPID[pid].flatMap(field) ?? "nil")"
            }.joined(separator: "; ")
        }
        check(ppidDiff.isEmpty, "ppid equal for all stable processes \(show(ppidDiff) { String($0.ppid) })")
        check(ttyDiff.isEmpty, "tty equal for all stable processes \(show(ttyDiff, \.tty))")
        check(ownCommDiff.isEmpty, "comm equal for own-user processes \(show(ownCommDiff) { $0.command })")
        check(ownArgsDiff.isEmpty, "args equal for own-user processes \(show(ownArgsDiff, \.args))")
        print("info other users' comm: \(otherComm.same) same, \(otherComm.sameName) same executable name, " +
              "\(otherComm.differ) different (ps reads their argv as root; native falls back to the executable path)")

        let stablePIDs = Set(stable.map(\.pid))
        func agents(_ table: ProcessTable) -> [String] {
            AgentProcessMatcher.agentProcesses(in: table).filter { stablePIDs.contains($0.proc.pid) }
                .map { "\($0.proc.pid):\($0.kind.rawValue)" }
        }
        check(agents(native) == agents(ps), "agent processes equal: \(agents(native))")

        // 进程组：取一个有终端的本用户进程，对照 `ps -o pgid= -t <tty>`。
        if let probe = stable.first(where: { $0.uid == uid && $0.tty != nil }), let tty = native.tty(of: probe.pid) {
            let nativeGroups = reader.processGroups(onTTYOf: probe.pid)
            let psGroups = Set((SystemProbe.run("/bin/ps", ["-o", "pgid=", "-t", tty]) ?? "")
                .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }).sorted()
            check(nativeGroups == psGroups, "process groups on \(tty): native \(nativeGroups) ps \(psGroups)")
            check(reader.ttyName(ofPID: probe.pid) == tty, "ttyName(ofPID:) = \(tty)")
        } else {
            print("SKIP process groups (no own process with a tty)")
        }

        // 耗时：ps（两次子进程）与原生（首次需读全部命令行；之后命中缓存）。
        func median(_ runs: Int, _ body: () -> Void) -> Double {
            var samples: [Double] = []
            for _ in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                body()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            return samples.sorted()[samples.count / 2]
        }
        let psMS = median(5) { _ = SystemProbe.psProcessTable() }
        let coldMS = median(5) { _ = NativeProcessReader().table() }
        let warmMS = median(21) { _ = reader.table() }
        print(String(format: "timing (median): ps %.1f ms, native cold %.2f ms, native warm %.2f ms", psMS, coldMS, warmMS))
        check(warmMS < psMS, "native warm is faster than ps")
        print(ok ? "proc selftest passed" : "proc selftest FAILED")
        return ok
    }
}
