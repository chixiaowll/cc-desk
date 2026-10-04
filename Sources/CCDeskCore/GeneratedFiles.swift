import Foundation

/// 项目目录监视（设计 §17.1「生成的文件」）的纯规则：哪些目录能监视、哪些路径算产出。
/// FSEvents 的流由 App 层（`ProjectWatcher`）管理，这里只做判断，便于测试。
public enum ProjectWatchRules {
    /// 整个目录树都不看的目录名（依赖、构建产物、缓存、版本库）。
    public static let ignoredDirectories: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".build", "build", "dist", "DerivedData", "__pycache__",
        ".venv", "venv", "target", ".next", ".nuxt", ".cache", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        ".gradle", ".swiftpm", ".tox", ".parcel-cache", ".turbo", ".idea",
    ]
    /// 编辑器 / 系统的临时文件与缓存文件名。
    public static let ignoredNames: Set<String> = [".DS_Store", "4913", ".localized"]
    public static let ignoredExtensions: Set<String> = ["swp", "swo", "swx", "tmp", "pyc", "crdownload", "part"]

    /// 不能监视的目录（太宽：根目录、家目录及其上层、家目录下的常用大目录）；返回 nil 表示可以监视。
    public enum Refusal: Equatable, Sendable {
        case tooBroad
    }

    public static func refusal(root: String, home: String = NSHomeDirectory()) -> Refusal? {
        let r = URL(fileURLWithPath: root).standardized.path
        let h = URL(fileURLWithPath: home).standardized.path
        if r == "/" || r == h || h.hasPrefix(r.hasSuffix("/") ? r : r + "/") { return .tooBroad }
        let broad = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
                     "Library/Mobile Documents/com~apple~CloudDocs"]
        if broad.contains(where: { r == h + "/" + $0 }) { return .tooBroad }
        if ["/Users", "/Volumes", "/private", "/tmp", "/var", "/Applications", "/System"].contains(r) { return .tooBroad }
        return nil
    }

    /// FSEvents 报来的路径是否算产出：在 root 下（不含 root 本身），路径上没有被忽略的目录，
    /// 文件名不是临时 / 交换文件（`*.swp`、`*~`、`.#*`、`.DS_Store`…）。只看路径，不碰文件系统。
    public static func shouldInclude(path: String, root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return false }
        let parts = path.dropFirst(prefix.count).split(separator: "/")
        guard let name = parts.last else { return false }
        if parts.dropLast().contains(where: { ignoredDirectories.contains(String($0)) }) { return false }
        if ignoredDirectories.contains(String(name)) || ignoredNames.contains(String(name)) { return false }
        if name.hasSuffix("~") || name.hasPrefix(".#") || name.hasPrefix(".~lock.") { return false }
        let ext = (String(name) as NSString).pathExtension.lowercased()
        return !ignoredExtensions.contains(ext)
    }
}

/// 选中会话期间项目目录里新出现 / 被改动的文件（最多保留 `maxKept` 个最近的）。
/// 同一文件在一阵连续写入里只算一条（按路径合并，更新时间）。值类型，不涉及文件系统。
public struct GeneratedFilesLog: Equatable, Sendable {
    public static let maxKept = 200

    struct Entry: Equatable, Sendable {
        var first: Date
        var last: Date
        var created: Bool
        var count: Int
        var sequence: Int
    }

    private(set) var entries: [String: Entry] = [:]
    private var sequence = 0

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// 记一次改动：created 为 FSEvents 的「新建」（含改名进来）。之前新建过的文件再被改动仍算新建。
    public mutating func record(_ path: String, created: Bool, at time: Date) {
        sequence += 1
        if var e = entries[path] {
            e.last = max(e.last, time)
            e.created = e.created || created
            e.count += 1
            e.sequence = sequence
            entries[path] = e
        } else {
            entries[path] = Entry(first: time, last: time, created: created, count: 1, sequence: sequence)
        }
        if entries.count > Self.maxKept, let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence }) {
            entries[oldest.key] = nil
        }
    }

    /// 文件被删掉 / 移走：不再列出。
    public mutating func remove(_ path: String) {
        entries[path] = nil
    }

    /// 快照：最近改动的在前。
    public func files(exists: (String) -> Bool = MentionedFiles.isRegularFile) -> [TouchedFile] {
        entries.sorted { $0.value.sequence > $1.value.sequence }.map { path, e in
            TouchedFile(path: path, firstTouched: e.first, lastTouched: e.last, action: e.created ? .created : .modified,
                        count: e.count, isDocument: TouchedFiles.isDocument(path), exists: exists(path), origin: .generated)
        }
    }
}

/// 工具写入、生成、提到三个来源的合并（设计 §17.2）。
public enum TouchedFilesMerge {
    /// 同一路径只出现一次，留信息量最大的来源（工具 > 生成 > 提到）。
    /// 返回：tool —— 工具写入的文件（原顺序：文档在前、代码在后）；extra —— 只被生成 / 提到的文件：
    /// 文档（含图片 / 视频）在前、其余在后，各自按最后改动 / 提到时间倒序，时间相同时生成的在前。
    public static func merge(tool: [TouchedFile], generated: [TouchedFile], mentioned: [TouchedFile])
        -> (tool: [TouchedFile], extra: [TouchedFile]) {
        let toolPaths = Set(tool.map(\.path))
        var extra: [String: (TouchedFile, Int)] = [:]
        for (index, file) in (generated + mentioned).enumerated() where !toolPaths.contains(file.path) {
            if let existing = extra[file.path], existing.0.origin <= file.origin { continue }
            extra[file.path] = (file, index)
        }
        let sorted = extra.values.sorted { a, b in
            if a.0.isDocument != b.0.isDocument { return a.0.isDocument }
            let ta = a.0.lastTouched ?? .distantPast, tb = b.0.lastTouched ?? .distantPast
            if ta != tb { return ta > tb }
            if a.0.origin != b.0.origin { return a.0.origin < b.0.origin }
            return a.1 < b.1
        }.map(\.0)
        return (tool, sorted)
    }
}
