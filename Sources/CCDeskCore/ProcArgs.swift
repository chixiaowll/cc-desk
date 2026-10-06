import Foundation

/// `sysctl(KERN_PROCARGS2)` 缓冲区的解析，以及与 `ps` 一致的 comm / args 取法（纯函数，便于测试）。
///
/// 缓冲区布局：前 4 字节为 argc（本机字节序 Int32），随后是以 `\0` 结尾的可执行文件路径、若干填充 `\0`，
/// 再依次是 argc 个以 `\0` 结尾的参数（之后是环境变量，不读）。
/// node 程序改 `process.title` 时会覆盖 argv 所在内存并补 `\0`（如 pi 显示为 "pi"），所以参数可以是空串，
/// 与 `ps` 一样每遇到一个 `\0` 就算一个参数结束，不跳过连续的 `\0`。
public enum ProcArgs {
    public struct Parsed: Equatable, Sendable {
        public let execPath: String
        public let argv: [String]

        public init(execPath: String, argv: [String]) {
            self.execPath = execPath
            self.argv = argv
        }

        /// `ps -o comm` 的值：argv[0]；为空时退回可执行文件路径。
        public var command: String? {
            if let first = argv.first, !first.isEmpty { return first }
            return execPath.isEmpty ? nil : execPath
        }

        /// `ps -o args` 的值：各参数以空格连接，控制字符按 ps 的 vis 写法转成三位八进制（换行为 `\012`），
        /// 去掉首尾空白；为空时 nil。
        public var args: String? {
            let joined = ProcArgs.visControls(argv.joined(separator: " ")).trimmingCharacters(in: .whitespaces)
            return joined.isEmpty ? nil : joined
        }
    }

    /// 控制字符（< 0x20 与 0x7F）转成 `\ooo`，其余（含 UTF-8 多字节字符、反斜杠）原样保留。
    static func visControls(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count + 8)
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                let octal = String(scalar.value, radix: 8)
                out += "\\" + String(repeating: "0", count: 3 - octal.count) + octal
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    public static func parse(_ bytes: [UInt8]) -> Parsed? {
        let intSize = MemoryLayout<Int32>.size
        guard bytes.count >= intSize else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) }
        guard argc >= 0 else { return nil }
        var i = intSize
        let pathStart = i
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        let execPath = String(decoding: bytes[pathStart..<i], as: UTF8.self)
        while i < bytes.count, bytes[i] == 0 { i += 1 }
        var argv: [String] = []
        argv.reserveCapacity(Int(argc))
        while argv.count < Int(argc), i < bytes.count {
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            // 没有结尾 \0 的残缺参数（缓冲区截断）丢弃。
            guard i < bytes.count else { break }
            argv.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        return Parsed(execPath: execPath, argv: argv)
    }
}

/// 原生进程表里每个进程的 comm / args 缓存策略：pid 会被复用、exec 会换掉命令，所以按
/// (启动时间, 内核短名 p_comm) 认定同一个进程；刚启动不久的进程可能还会改 `process.title`
/// （node 程序启动后才把标题设成 "pi"），在 `settleAge` 之内每次都重读。
public struct ProcessCommandKey: Equatable, Sendable {
    public let startSec: Int
    public let startUsec: Int
    public let shortName: String

    public init(startSec: Int, startUsec: Int, shortName: String) {
        self.startSec = startSec
        self.startUsec = startUsec
        self.shortName = shortName
    }

    /// 启动多久之后认为命令行不再变化。
    public static let settleAge: TimeInterval = 5

    public var startedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(startSec) + TimeInterval(startUsec) / 1_000_000)
    }

    /// 缓存里是 `cached`、现在看到的是 `self` 时要不要重读命令行。
    public func needsRefresh(cached: ProcessCommandKey?, now: Date) -> Bool {
        guard let cached, cached == self else { return true }
        return now.timeIntervalSince(startedAt) < Self.settleAge
    }
}
