import AppKit
import CCDeskCore

/// 右侧面板「文件」页（设计 §28）：选中会话所在项目的文件树。只在这一页显示时才读取：
/// git 项目跑一次 `git ls-files`（已跟踪 + 未跟踪且没被忽略的），其他目录有上限地遍历；
/// 页面显示期间每 15 秒、以及选中会话改动了文件时重新读。展开的目录按项目记住。只在主线程访问。
final class ProjectFilesModel: ObservableObject {
    static let refreshInterval: TimeInterval = 15

    @Published private(set) var root: String?
    @Published private(set) var tree: ProjectFileTree = .empty
    @Published private(set) var loading = false
    /// 是 git 项目（文件来自 git ls-files）。
    @Published private(set) var isGit = false
    @Published var expanded: Set<String> = [] {
        didSet { if let root { expandedByRoot[root] = expanded } }
    }
    @Published var query = ""
    /// 选中的相对路径（文件或目录）。
    @Published var selection: String?
    /// 选中会话改动过的文件（相对路径）与它们所在的目录，用来标小点。
    @Published private(set) var changed: Set<String> = []
    @Published private(set) var changedDirectories: Set<String> = []

    /// 「文件」页是否正在显示（面板展开且选中这一页）。
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            reschedule()
            if isActive { reload() }
        }
    }

    private var expandedByRoot: [String: Set<String>] = [:]
    private var timer: Timer?
    private var generation = 0
    private var reloading = false
    private var pendingReload = false
    private let queue = DispatchQueue(label: "cc-desk.project-files", qos: .userInitiated)

    /// 选中会话的项目根目录变了。
    func setRoot(_ newRoot: String?) {
        guard newRoot != root else { return }
        root = newRoot
        generation += 1
        tree = .empty
        isGit = false
        changed = []
        changedDirectories = []
        query = ""
        selection = nil
        expanded = newRoot.flatMap { expandedByRoot[$0] } ?? []
        reloading = false
        pendingReload = false
        if isActive { reload() }
    }

    /// 选中会话改动的文件（绝对路径）；有新文件时顺便重读一次树（agent 新建的文件马上出现）。
    func setChangedFiles(_ paths: [String]) {
        guard let root else { return }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let relative = Set(paths.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        guard relative != changed else { return }
        let added = !relative.subtracting(changed).isEmpty
        changed = relative
        changedDirectories = ProjectFileTree.ancestorDirectories(of: Array(relative))
        if added, isActive { reload() }
    }

    /// 后台重读文件树；正在读时记下，读完再来一次。
    func reload() {
        guard let root else { return }
        guard !reloading else {
            pendingReload = true
            return
        }
        reloading = true
        loading = tree.isEmpty
        let generation = self.generation
        queue.async { [weak self] in
            let (tree, git) = Self.load(root: root)
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.reloading = false
                self.loading = false
                if self.tree != tree { self.tree = tree }
                if self.isGit != git { self.isGit = git }
                if self.pendingReload {
                    self.pendingReload = false
                    self.reload()
                }
            }
        }
    }

    /// 太宽的目录（家目录等）不列：git ls-files 或遍历都可能很久，且没有意义。
    var isTooBroad: Bool {
        root.map { ProjectWatchRules.refusal(root: $0) != nil } ?? false
    }

    private static func load(root: String) -> (ProjectFileTree, Bool) {
        if ProjectWatchRules.refusal(root: root) != nil { return (.empty, false) }
        // -c core.quotepath=off 与 -z：中文 / 空格文件名原样输出。
        let args = ["-c", "core.quotepath=off", "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        if FileManager.default.fileExists(atPath: "/usr/bin/git"),
           case .exited(let out) = ProcessRunner.capture("/usr/bin/git", args, environment: nil,
                                                          cwd: URL(fileURLWithPath: root), timeout: 10,
                                                          maxOutputBytes: 32 * 1024 * 1024),
           out.status == 0 {
            // 已跟踪但工作区里删掉的文件不列。
            let base = root.hasSuffix("/") ? root : root + "/"
            let paths = ProjectFileTree.parseGitList(out.stdout).filter {
                FileManager.default.fileExists(atPath: base + $0)
            }
            return (ProjectFileTree(files: paths, truncated: out.truncated), true)
        }
        return (ProjectFileTree.scan(root: root), false)
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard isActive else { return }
        let t = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in self?.reload() }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: 浏览

    /// 当前显示的行：有搜索词时是搜索结果（平铺），否则是按展开状态铺平的树。
    var rows: [ProjectFileEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? tree.visibleEntries(expanded: expanded) : tree.search(q)
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func absolutePath(_ relative: String) -> String? {
        guard let root else { return nil }
        return (root as NSString).appendingPathComponent(relative)
    }

    func toggle(_ directory: String) {
        if expanded.contains(directory) { expanded.remove(directory) } else { expanded.insert(directory) }
    }

    /// 收起全部目录。
    func collapseAll() { expanded = [] }

    /// 在树里定位某个文件：展开它的各级目录并选中（搜索结果里回车 / 「在树中显示」）。
    func reveal(_ relative: String) {
        var parent = (relative as NSString).deletingLastPathComponent
        var dirs = expanded
        while !parent.isEmpty {
            dirs.insert(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        expanded = dirs
        query = ""
        selection = relative
    }

    /// ↑ / ↓ 移动选中。
    func moveSelection(by delta: Int) {
        let list = rows
        guard !list.isEmpty else { return }
        let current = selection.flatMap { s in list.firstIndex { $0.relativePath == s } }
        let next = current.map { min(max($0 + delta, 0), list.count - 1) } ?? (delta > 0 ? 0 : list.count - 1)
        selection = list[next].relativePath
    }

    /// ← 收起选中的目录（已收起或是文件时跳到父目录）；→ 展开选中的目录。
    func horizontal(expand: Bool) {
        guard let selection, let entry = rows.first(where: { $0.relativePath == selection }) else { return }
        if expand {
            if entry.isDirectory { expanded.insert(entry.relativePath) }
        } else if entry.isDirectory, expanded.contains(entry.relativePath) {
            expanded.remove(entry.relativePath)
        } else if !entry.parent.isEmpty {
            self.selection = entry.parent
        }
    }
}
