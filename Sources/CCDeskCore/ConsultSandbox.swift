import Foundation

/// 接口版顾问（设计 §22）的只读工具：只能看项目目录里的东西。
///
/// - 路径：相对项目根目录（也接受落在根目录内的绝对路径）；用 realpath 解析符号链接与 `..` 后必须仍在根目录内，
///   指向外面的符号链接因此读不到。
/// - read_file：普通文件、最多读 `maxFileBytes`、含 NUL 的当作二进制拒绝；按行返回（带行号）。
/// - search：`/usr/bin/grep -rnI`（参数数组，模式经 `-e` 传入，不会被当作选项；BSD grep 递归时默认不跟随符号链接），
///   工作目录为根目录，结果条数与字数有上限。
/// - git：只读子命令，固定加 `--no-ext-diff --no-textconv`，ref 只接受普通的提交 / 分支写法（不能以 `-` 开头），
///   路径放在 `--` 之后；环境用 `GitSafety`（由调用方提供的 runner 负责）。
public struct ConsultSandbox: Sendable {
    public static let maxFileBytes = 256 * 1024
    public static let maxOutputChars = 30_000
    public static let maxListEntries = 300
    public static let maxSearchLines = 200

    /// 根目录的真实路径。
    public let root: String

    /// 项目目录不存在 / 不是目录时 nil。
    public init?(project: String) {
        guard let real = Self.realpath(project) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else { return nil }
        root = real
    }

    public enum Failure: Error, Equatable, Sendable {
        case outside(String)
        case notFound(String)
        case invalid(String)

        public var message: String {
            switch self {
            case .outside(let p): return "\(p) is outside the project; only files inside the project can be read"
            case .notFound(let p): return "\(p) does not exist"
            case .invalid(let m): return m
            }
        }
    }

    /// 解析一个路径（nil / 空 / "." = 根目录），返回在根目录内的真实路径。
    public func resolve(_ path: String?) -> Result<String, Failure> {
        let given = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if given.isEmpty || given == "." { return .success(root) }
        guard !given.contains("\0") else { return .failure(.invalid("invalid path")) }
        let joined = given.hasPrefix("/") ? given : (root as NSString).appendingPathComponent(given)
        let lexical = (joined as NSString).standardizingPath
        // 先按字面判断（不存在的文件也要报「在外面」而不是「不存在」）。
        guard contains(lexical) || contains(Self.realpath((lexical as NSString).deletingLastPathComponent) ?? "") else {
            return .failure(.outside(given))
        }
        guard let real = Self.realpath(joined) else { return .failure(.notFound(given)) }
        guard contains(real) else { return .failure(.outside(given)) }
        return .success(real)
    }

    /// 相对根目录的路径（根目录本身为 "."）。
    public func relative(_ real: String) -> String {
        real == root ? "." : String(real.dropFirst(root.count + 1))
    }

    private func contains(_ path: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: 文件

    public func readFile(_ path: String?, startLine: Int?, maxLines: Int?) -> Result<String, Failure> {
        guard let path, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(.invalid("path is required")) }
        let real: String
        switch resolve(path) {
        case .failure(let f): return .failure(f)
        case .success(let r): real = r
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: real, isDirectory: &isDir)
        if isDir.boolValue { return .failure(.invalid("\(path) is a directory; use list_dir")) }
        guard let handle = FileHandle(forReadingAtPath: real) else { return .failure(.invalid("cannot read \(path)")) }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: real)[.size] as? Int) ?? 0
        let data = (try? handle.read(upToCount: Self.maxFileBytes)) ?? Data()
        if data.contains(0) { return .failure(.invalid("\(path) looks like a binary file")) }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        let start = max(1, startLine ?? 1)
        let count = min(2000, max(1, maxLines ?? 400))
        guard start <= lines.count else { return .failure(.invalid("\(path) has only \(lines.count) lines")) }
        let slice = lines[(start - 1)..<min(lines.count, start - 1 + count)]
        var out = slice.enumerated().map { "\(start + $0.offset)\t\($0.element)" }.joined(separator: "\n")
        let end = start - 1 + slice.count
        if end < lines.count { out += "\n…(lines \(end + 1)–\(lines.count) not shown; use start_line)" }
        if size > Self.maxFileBytes { out += "\n…(file is \(size) bytes; only the first \(Self.maxFileBytes) were read)" }
        return .success(Self.clip(out))
    }

    public func listDir(_ path: String?) -> Result<String, Failure> {
        let real: String
        switch resolve(path) {
        case .failure(let f): return .failure(f)
        case .success(let r): real = r
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: real) else {
            return .failure(.invalid("\(path ?? ".") is not a directory"))
        }
        let entries = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name -> String in
            let full = (real as NSString).appendingPathComponent(name)
            if let type = try? fm.attributesOfItem(atPath: full)[.type] as? FileAttributeType, type == .typeSymbolicLink {
                return name + "@"
            }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            return isDir.boolValue ? name + "/" : name
        }
        var out = entries.prefix(Self.maxListEntries).joined(separator: "\n")
        if entries.count > Self.maxListEntries { out += "\n…(\(entries.count - Self.maxListEntries) more)" }
        return .success(entries.isEmpty ? "(empty)" : out)
    }

    // MARK: 命令

    /// grep 的参数（不含可执行文件；工作目录为根目录）。
    public func searchArguments(pattern: String?, regex: Bool, ignoreCase: Bool, path: String?) -> Result<[String], Failure> {
        guard let pattern, !pattern.isEmpty else { return .failure(.invalid("pattern is required")) }
        guard !pattern.contains("\0"), !pattern.contains("\n") else { return .failure(.invalid("pattern must be one line")) }
        let real: String
        switch resolve(path) {
        case .failure(let f): return .failure(f)
        case .success(let r): real = r
        }
        var args = ["-rnI", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=.build"]
        args.append(regex ? "-E" : "-F")
        if ignoreCase { args.append("-i") }
        args += ["-e", pattern, "--", relative(real)]
        return .success(args)
    }

    public enum GitTool: String, Sendable {
        case status = "git_status", diff = "git_diff", log = "git_log"
    }

    /// git 的参数（不含可执行文件）：`-C <根目录> --no-pager <子命令> …`。
    public func gitArguments(_ tool: GitTool, staged: Bool = false, ref: String? = nil, path: String? = nil,
                             count: Int? = nil) -> Result<[String], Failure> {
        var pathspec: [String] = []
        if let path, !path.trimmingCharacters(in: .whitespaces).isEmpty {
            switch resolve(path) {
            case .failure(let f): return .failure(f)
            case .success(let r): pathspec = ["--", relative(r)]
            }
        }
        let refs: [String]
        if let ref = ref?.trimmingCharacters(in: .whitespaces), !ref.isEmpty {
            guard Self.isSafeRef(ref) else { return .failure(.invalid("invalid ref \(ref)")) }
            refs = [ref]
        } else {
            refs = []
        }
        let base = ["-C", root, "--no-pager"]
        switch tool {
        case .status:
            return .success(base + ["status", "--short", "--branch"])
        case .diff:
            return .success(base + ["diff", "--no-ext-diff", "--no-textconv", "--no-color"] + (staged ? ["--cached"] : [])
                            + refs + (pathspec.isEmpty ? ["--"] : pathspec))
        case .log:
            let n = min(100, max(1, count ?? 20))
            return .success(base + ["log", "-n", String(n), "--no-color", "--date=short", "--format=%h %ad %an %s"]
                            + refs + (pathspec.isEmpty ? ["--"] : pathspec))
        }
    }

    /// 普通的提交 / 分支 / 范围写法：字母数字开头，只含 `._/~^@{}-` 与 `..`；不能是选项。
    public static func isSafeRef(_ ref: String) -> Bool {
        guard ref.count <= 200, let first = ref.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/~^@{}-")
        return ref.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// 命令输出 → 给模型的文字（截断；grep 限制行数）。
    public static func searchOutput(_ output: String, status: Int32) -> String {
        if status == 1 && output.isEmpty { return "No matches." }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        var out = lines.prefix(maxSearchLines).map { String($0.prefix(300)) }.joined(separator: "\n")
        if lines.count > maxSearchLines { out += "\n…(\(lines.count - maxSearchLines) more matches; narrow the search)" }
        return clip(out)
    }

    public static func clip(_ text: String) -> String {
        text.count > maxOutputChars ? String(text.prefix(maxOutputChars)) + "\n…(truncated)" : text
    }

    static func realpath(_ path: String) -> String? {
        guard !path.isEmpty, let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
