import AppKit
import Combine
import CCDeskCore

/// 「改动的文件」面板的状态（设计 §17）：只跟踪选中的会话，在后台串行队列上增量读它的会话记录。
/// 面板显示时每 2 秒、隐藏时每 6 秒看一次文件大小 / 修改时间，变了才读新增部分；隐藏时只为「有新文档」的小圆点服务。
/// 三个来源：工具写入（`files`）、agent 回复里提到的、选中期间项目目录里生成的（合并后只在两者之一的进 `extraFiles`）；
/// 项目监视见 `TouchedFilesModel+Watch`。
/// 只在主线程访问；`tracker` 只在 `queue` 上访问。
final class TouchedFilesModel: ObservableObject {
    static let shownKey = "touchedFilesPanelShown"
    static let visibleInterval: TimeInterval = 2
    static let hiddenInterval: TimeInterval = 6

    /// 面板是否展开（记在 UserDefaults）。
    /// 面板宽度（拖动分隔线调整，记住上次的值）。
    @Published var panelWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: TouchedFilesModel.widthKey)
        return stored > 0 ? min(max(CGFloat(stored), TouchedFilesModel.minWidth), TouchedFilesModel.maxWidth) : 300
    }() {
        didSet { UserDefaults.standard.set(Double(panelWidth), forKey: Self.widthKey) }
    }
    static let widthKey = "touchedFilesPanelWidth"
    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 560
    /// 拖到比这更窄就收起面板。
    static let collapseWidth: CGFloat = 160

    @Published var isShown: Bool = UserDefaults.standard.bool(forKey: TouchedFilesModel.shownKey) {
        didSet {
            guard isShown != oldValue else { return }
            UserDefaults.standard.set(isShown, forKey: Self.shownKey)
            if isShown { markSeen() } else { preview.close() }
            reschedule()
            if isShown { refresh(force: true) }
        }
    }
    /// 工具写入的文件（文档在前、代码在后）。
    @Published private(set) var files: [TouchedFile] = []
    /// 只被提到 / 生成的文件（不与 `files` 重复；文档与图片 / 视频在前）。
    @Published private(set) var extraFiles: [TouchedFile] = []
    /// 项目监视没开的原因（目录太宽 / 启动失败）；nil 表示正常监视或没有会话。
    @Published var watchNote: WatchNote?
    /// 当前会话的状态：没有 agent 会话 / 正在找记录 / 找不到记录 / 已加载。
    @Published private(set) var phase: Phase = .noSession
    /// 选中会话的 agent 新建了你上次打开面板之后没见过的文档。
    @Published private(set) var hasUnseenDocument = false
    @Published var selection: String?
    @Published var filter = ""
    /// 当前会话的项目根目录（相对路径的基准）。
    @Published private(set) var root: String?

    enum Phase: Equatable {
        case noSession, locating, notFound, loaded
    }

    enum WatchNote: Equatable {
        case tooBroad, failed
    }

    struct Target: Equatable {
        let kind: AgentKind
        let sessionID: String
        let cwd: String
        var key: String { "\(kind.rawValue):\(sessionID)" }
    }

    weak var model: AppModel?
    let preview = FilePreviewController()
    private(set) var target: Target?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "cc-desk.touched-files", qos: .utility)
    /// 只在 `queue` 上访问。
    private var tracker: TouchedFilesTracker?
    private var trackerURL: URL?
    private var locating = false
    private var refreshing = false
    /// 切换会话时加一，丢弃过时的后台结果。
    private var generation = 0 {
        didSet { latestGeneration.set(generation) }
    }
    /// `generation` 的线程安全副本：后台读取大文件时据此提前停下（用户已切到别的会话）。
    private let latestGeneration = LockedValue(0)
    /// 快速查看正在显示面板列表（而不是终端里 ⌘-点击的单个文件）：列表变化时才同步过去。
    private var previewFromList = false
    /// 会话 -> 上次打开面板时（或第一次加载时）已有的新建文档；之后多出来的才算「新」。
    private var seenDocuments: [String: Set<String>] = [:]
    /// 各来源最近一次的快照（主线程），合并成 `files` / `extraFiles`。
    private var toolSnapshot: [TouchedFile] = []
    private var mentionSnapshot: [TouchedFile] = []
    var generatedSnapshot: [TouchedFile] = []
    /// 当前的项目监视（一次只有一个）与各会话停下时的记录 / 回放位置，见 `TouchedFilesModel+Watch`。
    var watcher: ProjectWatcher?
    var watchMemory: [String: WatchMemory] = [:]
    var watchMemoryOrder: [String] = []
    /// 会话 id -> 第一次在侧栏看到它时的事件编号与时刻：第一次选中时从这里回放。
    var firstSeen: [String: WatchMemory.Start] = [:]

    init(model: AppModel) {
        self.model = model
    }

    // MARK: 选中的会话

    /// 选中的会话变了（或它的 sessionId / cwd 变了）。非 agent 会话或还没有 sessionId 时清空。
    func select(row: SidebarRow?) {
        let next: Target? = row.flatMap { row in
            guard row.session.kind.isAgent, let sid = row.session.sessionID else { return nil }
            return Target(kind: row.session.kind, sessionID: sid, cwd: row.session.cwd)
        }
        root = row.flatMap { model?.projectRoot(forCwd: $0.session.cwd) } ?? row?.session.cwd
        guard next != target else { return }
        stopWatcher()  // 先按旧会话存下监视记录
        target = next
        generation += 1
        files = []
        extraFiles = []
        toolSnapshot = []
        mentionSnapshot = []
        generatedSnapshot = []
        selection = nil
        filter = ""
        hasUnseenDocument = false
        trackerURL = nil
        locating = false
        refreshing = false
        phase = next == nil ? .noSession : .locating
        queue.async { [weak self] in self?.tracker = nil }
        restartWatcher(root: root)
        reschedule()
        refresh(force: true)
    }

    /// 当前代号（监视回调据此丢弃切换会话之前的结果）。
    var currentGeneration: Int { generation }

    // MARK: 刷新

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard target != nil else { return }
        let interval = isShown ? Self.visibleInterval : Self.hiddenInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh(force: false) }
        t.tolerance = interval / 4
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// force：面板刚打开 / 刚切换会话时即使记录没变也重新检查文件是否还在。
    func refresh(force: Bool) {
        guard let target, let model, !refreshing else { return }
        guard let url = trackerURL else {
            guard !locating else { return }
            locating = true
            let generation = self.generation
            model.locateTranscript(kind: target.kind, sessionID: target.sessionID) { [weak self] url in
                guard let self, self.generation == generation else { return }
                self.locating = false
                guard let url else {
                    self.phase = .notFound
                    return
                }
                self.trackerURL = url
                self.refresh(force: true)
            }
            return
        }
        refreshing = true
        let generation = self.generation
        let visible = isShown
        queue.async { [weak self] in
            guard let self else { return }
            let tracker = self.tracker.flatMap { $0.url == url ? $0 : nil }
                ?? TouchedFilesTracker(url: url, kind: target.kind, cwd: target.cwd)
            self.tracker = tracker
            let latest = self.latestGeneration
            let changed = tracker.refresh { latest.get() == generation }
            // 面板显示时每次都检查文件是否还在（用户可能删掉了）；隐藏时只在记录变化后重算。
            let recompute = changed || force || visible
            let snapshot: [TouchedFile]? = recompute ? tracker.log.files() : nil
            let mentions: [TouchedFile]? = recompute ? tracker.log.mentions.files() : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.refreshing = false
                self.phase = .loaded
                guard let snapshot, let mentions,
                      snapshot != self.toolSnapshot || mentions != self.mentionSnapshot else { return }
                self.toolSnapshot = snapshot
                self.mentionSnapshot = mentions
                self.recomputeFiles()
            }
        }
    }

    /// 合并三个来源；有变化才发布（每次赋值都会让面板重绘）。
    func recomputeFiles() {
        let merged = TouchedFilesMerge.merge(tool: toolSnapshot, generated: generatedSnapshot, mentioned: mentionSnapshot)
        guard merged.tool != files || merged.extra != extraFiles else { return }
        files = merged.tool
        extraFiles = merged.extra
        if let selection, !allFiles.contains(where: { $0.path == selection }) { self.selection = nil }
        updateUnseen()
        syncPreview()
    }

    /// 面板里的全部文件，按显示顺序：工具写入的文档、代码，再是提到 / 生成的。
    var allFiles: [TouchedFile] { files + extraFiles }

    // MARK: 新文档提示

    /// 算「新文档」的：工具新建的文档，生成的新文档 / 图片 / 视频，提到的文档。
    private var createdDocuments: Set<String> {
        Set(allFiles.filter { $0.isDocument && ($0.action == .created || $0.origin == .mentioned) }.map(\.path))
    }

    private func updateUnseen() {
        guard let key = target?.key else { return }
        let created = createdDocuments
        if isShown {
            seenDocuments[key] = created
            hasUnseenDocument = false
        } else if let seen = seenDocuments[key] {
            hasUnseenDocument = !created.subtracting(seen).isEmpty
        } else {
            // 第一次看到这个会话：已有的文档不算新的。
            seenDocuments[key] = created
        }
    }

    private func markSeen() {
        guard let key = target?.key, phase == .loaded else { return }
        seenDocuments[key] = createdDocuments
        hasUnseenDocument = false
    }

    // MARK: 列表

    /// 按筛选词过滤后的文件（文件名或相对路径包含筛选词，不区分大小写）。
    var visibleFiles: [TouchedFile] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return allFiles }
        return allFiles.filter { $0.relativePath(root: root).lowercased().contains(query) }
    }

    func relativePath(_ file: TouchedFile) -> String {
        file.relativePath(root: root)
    }

    /// 行里第二行显示的所在目录（项目内相对根目录，项目外 "~/…" 并从中间省略）。
    func displayDirectory(_ file: TouchedFile) -> String {
        TouchedFiles.displayDirectory(file.path, root: root)
    }

    /// ↑ / ↓ 移动选中（没有选中时从第一个 / 最后一个开始）。
    func moveSelection(by delta: Int) {
        let list = visibleFiles
        guard !list.isEmpty else { return }
        let current = selection.flatMap { s in list.firstIndex { $0.path == s } }
        let next = current.map { min(max($0 + delta, 0), list.count - 1) } ?? (delta > 0 ? 0 : list.count - 1)
        selection = list[next].path
        syncPreview()
    }

    // MARK: 动作

    /// 快速查看（已打开时关闭）。预览列表是当前可见、仍存在的文件，↑ / ↓ 在面板里切换并同步选中。
    func toggleQuickLook(_ path: String? = nil, window: NSWindow?) {
        if FilePreviewController.isVisible, path == nil || path == selection {
            preview.close()
            return
        }
        if let path { selection = path }
        let previewable = visibleFiles.filter(\.exists)
        guard let selected = selection, let index = previewable.firstIndex(where: { $0.path == selected }) else { return }
        previewFromList = true
        preview.show(previewable.map { URL(fileURLWithPath: $0.path) }, index: index, in: window) { [weak self] i in
            guard let self else { return }
            let list = self.visibleFiles.filter(\.exists)
            if list.indices.contains(i) { self.selection = list[i].path }
        }
    }

    /// 列表选中或内容变化时，让已打开的快速查看跟着走。
    private func syncPreview() {
        guard previewFromList, FilePreviewController.isVisible else { return }
        let previewable = visibleFiles.filter(\.exists)
        guard let selected = selection, let index = previewable.firstIndex(where: { $0.path == selected }) else { return }
        preview.update(previewable.map { URL(fileURLWithPath: $0.path) }, index: index)
    }

    /// 终端里 ⌘-点击的文件：单独快速查看。
    func quickLook(path: String, window: NSWindow?) {
        previewFromList = false
        preview.show([URL(fileURLWithPath: path)], index: 0, in: window)
    }

    /// 任意会话的文件列表（一次性读取；选中的会话直接用已加载的结果）；completion 在主线程。
    func files(for row: SidebarRow, completion: @escaping ([TouchedFile]?) -> Void) {
        guard row.session.kind.isAgent, let sid = row.session.sessionID, let model else { return completion(nil) }
        let target = Target(kind: row.session.kind, sessionID: sid, cwd: row.session.cwd)
        if target == self.target, phase == .loaded { return completion(allFiles) }
        model.locateTranscript(kind: target.kind, sessionID: sid) { [weak self] url in
            guard let url, let self else { return completion(nil) }
            self.queue.async {
                let tracker = TouchedFilesTracker(url: url, kind: target.kind, cwd: target.cwd)
                tracker.refresh()
                let merged = TouchedFilesMerge.merge(tool: tracker.log.files(), generated: [],
                                                     mentioned: tracker.log.mentions.files())
                let files = merged.tool + merged.extra
                DispatchQueue.main.async { completion(files) }
            }
        }
    }

    /// 语音助手 `open_file`：最近的一个文档（含图片 / 视频；工具写入、生成、提到的都算，可按名字筛选）；
    /// 没有文档时退回最近的任意文件。时间相同时生成 / 提到的优先（「打开它刚生成的图片」）。
    static func latestFile(in files: [TouchedFile], matching query: String?) -> TouchedFile? {
        let existing = files.filter(\.exists)
        let q = query?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let matched = q.isEmpty ? existing : existing.filter { $0.path.lowercased().contains(q) }
        let byTime = matched.sorted { a, b in
            let ta = a.lastTouched ?? .distantPast, tb = b.lastTouched ?? .distantPast
            if ta != tb { return ta > tb }
            return a.origin > b.origin
        }
        return byTime.first(where: \.isDocument) ?? byTime.first
    }
}

/// 加锁的小值（主线程写、后台读）。
final class LockedValue<Value> {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
