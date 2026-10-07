import Foundation

/// 文件树里的一项（目录或文件），路径相对项目根目录。
public struct ProjectFileEntry: Equatable, Hashable, Sendable, Identifiable {
    public let relativePath: String
    public let isDirectory: Bool
    public var id: String { relativePath }
    public var name: String { (relativePath as NSString).lastPathComponent }
    /// 父目录（根目录下的项为 ""）。
    public var parent: String { (relativePath as NSString).deletingLastPathComponent }
    /// 层级（根目录下为 0）。
    public var depth: Int { relativePath.split(separator: "/").count - 1 }

    public init(relativePath: String, isDirectory: Bool) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
    }
}

/// 右侧面板「文件」页的文件清单（设计 §28）：git 项目来自 `git ls-files`（已跟踪 + 未跟踪且没被忽略的），
/// 其他目录来自有上限的目录遍历（跳过依赖 / 构建 / 缓存目录）。值类型，构建好以后只读。
public struct ProjectFileTree: Equatable, Sendable {
    /// 最多收这么多个文件；超过时 `truncated`（面板里说明只列出了一部分）。
    public static let maxFiles = 50_000

    public let files: [String]
    public let truncated: Bool
    /// 目录 -> 直接子项（目录在前，再按名字自然排序）。
    private var childrenByDirectory: [String: [ProjectFileEntry]]

    public init(files: [String], truncated: Bool = false) {
        var unique = Array(Set(files.filter { !$0.isEmpty && !$0.hasSuffix("/") }))
        var cut = truncated
        if unique.count > Self.maxFiles {
            unique.sort()
            unique = Array(unique.prefix(Self.maxFiles))
            cut = true
        }
        self.truncated = cut
        var children: [String: Set<ProjectFileEntry>] = [:]
        for path in unique {
            var current = path
            var isDirectory = false
            // 把文件和它的每一级目录挂到各自的父目录下（父目录已经有这一项时，更上层也一定已经挂过）。
            while !current.isEmpty {
                let parent = (current as NSString).deletingLastPathComponent
                let (inserted, _) = children[parent, default: []].insert(
                    ProjectFileEntry(relativePath: current, isDirectory: isDirectory))
                if !inserted { break }
                current = parent
                isDirectory = true
            }
        }
        childrenByDirectory = children.mapValues { set in
            set.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        self.files = unique.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static let empty = ProjectFileTree(files: [])

    public var isEmpty: Bool { files.isEmpty }

    public func children(of directory: String) -> [ProjectFileEntry] {
        childrenByDirectory[directory] ?? []
    }

    /// 展开的目录按树形顺序铺平成行（收起的目录不展开子项）。
    public func visibleEntries(expanded: Set<String>) -> [ProjectFileEntry] {
        var out: [ProjectFileEntry] = []
        func walk(_ dir: String) {
            for entry in children(of: dir) {
                out.append(entry)
                if entry.isDirectory, expanded.contains(entry.relativePath) { walk(entry.relativePath) }
            }
        }
        walk("")
        return out
    }

    /// 按文件名 / 路径搜索：空格分开的每个词都要出现（不分大小写）；文件名命中的排在前面，再按路径短的在前。
    public func search(_ query: String, limit: Int = 300) -> [ProjectFileEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var scored: [(score: Int, path: String)] = []
        for path in files {
            let lower = path.lowercased()
            guard words.allSatisfy({ lower.contains($0) }) else { continue }
            let name = (lower as NSString).lastPathComponent
            let inName = words.filter { name.contains($0) }.count
            let prefix = words.first.map { name.hasPrefix($0) } ?? false
            scored.append((score: (prefix ? 2000 : 0) + inName * 1000 - path.count, path: path))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
        return scored.prefix(limit).map { ProjectFileEntry(relativePath: $0.path, isDirectory: false) }
    }

    /// 某些文件所在的各级目录（给目录标「里面有改动」的小点）。
    public static func ancestorDirectories(of paths: [String]) -> Set<String> {
        var dirs: Set<String> = []
        for path in paths {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, dirs.insert(parent).inserted {
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return dirs
    }

    /// `git ls-files -z` 的输出（NUL 分隔）。
    public static func parseGitList(_ output: String) -> [String] {
        output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    /// 不是 git 项目时遍历目录：跳过 `ProjectWatchRules` 里的依赖 / 构建 / 缓存目录与临时文件，
    /// 隐藏目录（`.xxx/`）整个跳过，隐藏文件保留（`.env.example`、`.gitignore` 这类常要看）。最多 `limit` 个文件。
    public static func scan(root: String, limit: Int = 20_000, fileManager: FileManager = .default) -> ProjectFileTree {
        // 按相对路径遍历：不受 /var → /private/var 这类符号链接前缀影响。
        guard let walker = fileManager.enumerator(atPath: root) else { return .empty }
        var files: [String] = []
        var truncated = false
        while let path = walker.nextObject() as? String {
            let name = (path as NSString).lastPathComponent
            if walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                if ProjectWatchRules.ignoredDirectories.contains(name) || name.hasPrefix(".") { walker.skipDescendants() }
                continue
            }
            if ProjectWatchRules.ignoredNames.contains(name) || name.hasSuffix("~") { continue }
            if ProjectWatchRules.ignoredExtensions.contains((name as NSString).pathExtension.lowercased()) { continue }
            files.append(path)
            if files.count >= limit {
                truncated = true
                break
            }
        }
        return ProjectFileTree(files: files, truncated: truncated)
    }
}
