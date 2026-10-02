import Foundation

public struct ProcInfo: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    /// 例如 "ttys007"；无终端时为 nil。
    public let tty: String?
    public let command: String
}

/// `ps -axo pid=,ppid=,tty=,comm=` 的解析结果。
public struct ProcessTable: Sendable {
    public let byPID: [Int32: ProcInfo]

    public init(byPID: [Int32: ProcInfo]) {
        self.byPID = byPID
    }

    public static func parse(_ output: String) -> ProcessTable {
        var result: [Int32: ProcInfo] = [:]
        for line in output.split(separator: "\n") {
            var rest = Substring(line)
            func nextField() -> Substring? {
                rest = rest.drop(while: { $0 == " " || $0 == "\t" })
                guard !rest.isEmpty else { return nil }
                let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) ?? rest.endIndex
                let field = rest[..<end]
                rest = rest[end...]
                return field
            }
            guard let pidField = nextField(), let pid = Int32(pidField),
                  let ppidField = nextField(), let ppid = Int32(ppidField),
                  let ttyField = nextField()
            else { continue }
            let command = rest.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { continue }
            let tty = ttyField.hasPrefix("?") ? nil : String(ttyField)
            result[pid] = ProcInfo(pid: pid, ppid: ppid, tty: tty, command: command)
        }
        return ProcessTable(byPID: result)
    }

    public func isAlive(_ pid: Int32) -> Bool {
        byPID[pid] != nil
    }

    public func tty(of pid: Int32) -> String? {
        byPID[pid]?.tty
    }

    /// 由近到远的祖先进程，不含自身；遇到环或 64 层后停止。
    public func ancestors(of pid: Int32) -> [ProcInfo] {
        var chain: [ProcInfo] = []
        var seen: Set<Int32> = [pid]
        var current = byPID[pid]?.ppid
        while let p = current, let info = byPID[p], !seen.contains(p), chain.count < 64 {
            chain.append(info)
            seen.insert(p)
            current = info.ppid
        }
        return chain
    }

    public func hasAncestor(of pid: Int32, where predicate: (ProcInfo) -> Bool) -> Bool {
        ancestors(of: pid).contains(where: predicate)
    }
}
