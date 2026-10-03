import Foundation

public struct ProcInfo: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    /// 例如 "ttys007"；无终端时为 nil。
    public let tty: String?
    /// `ps` 的 comm 列：可执行文件路径（或进程自设的标题，如 node 程序设置的 "pi"）。
    public let command: String
    /// 完整命令行（`ps -axo pid=,args=`）；未取到时为 nil。
    public let args: String?

    public init(pid: Int32, ppid: Int32, tty: String?, command: String, args: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.tty = tty
        self.command = command
        self.args = args
    }

    /// comm 的最后一段路径，如 "/opt/.../bin/codex" -> "codex"。
    public var executableName: String {
        command.split(separator: "/").last.map(String.init) ?? command
    }

    /// 命令行按空白拆分后的各段（路径中含空格时会被拆开，只用于粗略判断子命令 / 参数）。
    public var argv: [String] {
        (args ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }
}

/// `ps -axo pid=,ppid=,tty=,comm=` 的解析结果，可再合并 `ps -axo pid=,args=` 的命令行。
/// comm 必须在行尾（路径可能含空格），所以命令行另用一次 ps 取得、按 pid 合并。
public struct ProcessTable: Sendable {
    public let byPID: [Int32: ProcInfo]

    public init(byPID: [Int32: ProcInfo]) {
        self.byPID = byPID
    }

    /// `argsOutput` 为 `ps -axo pid=,args=` 的输出；两次 ps 之间新出现的进程没有 args。
    public static func parse(_ output: String, args argsOutput: String? = nil) -> ProcessTable {
        let argsByPID = argsOutput.map(parseArgs) ?? [:]
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
            result[pid] = ProcInfo(pid: pid, ppid: ppid, tty: tty, command: command, args: argsByPID[pid])
        }
        return ProcessTable(byPID: result)
    }

    /// 解析 `ps -axo pid=,args=`：首段为 pid，其余（trim 后）为完整命令行。
    static func parseArgs(_ output: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let end = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(trimmed[..<end]) else { continue }
            let args = trimmed[end...].trimmingCharacters(in: .whitespaces)
            if !args.isEmpty { result[pid] = args }
        }
        return result
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
