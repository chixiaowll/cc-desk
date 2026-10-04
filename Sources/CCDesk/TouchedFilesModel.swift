import AppKit
import Combine
import CCDeskCore

/// 「改动的文件」面板的状态（设计 §17）：只跟踪选中的会话，在后台串行队列上增量读它的会话记录。
/// 面板显示时每 2 秒、隐藏时每 6 秒看一次文件大小 / 修改时间，变了才读新增部分；隐藏时只为「有新文档」的小圆点服务。
/// 只在主线程访问；`tracker` 只在 `queue` 上访问。
final class TouchedFilesModel: ObservableObject {
    static let shownKey = "touchedFilesPanelShown"
    static let visibleInterval: TimeInterval = 2
    static let hiddenInterval: TimeInterval = 6

    /// 面板是否展开（记在 UserDefaults）。
    @Published var isShown: Bool = UserDefaults.standard.bool(forKey: TouchedFilesModel.shownKey) {
        didSet {
            guard isShown != oldValue else { return }
            UserDefaults.standard.set(isShown, forKey: Self.shownKey)
            if isShown { markSeen() } else { preview.close() }
            reschedule()
            if isShown { refresh(force: true) }
        }
    }
    @Published private(set) var files: [TouchedFile] = []
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
        target = next
        generation += 1
        files = []
        selection = nil
        filter = ""
        hasUnseenDocument = false
        trackerURL = nil
        locating = false
        refreshing = false
        phase = next == nil ? .noSession : .locating
        queue.async { [weak self] in self?.tracker = nil }
        reschedule()
        refresh(force: true)
    }

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
            let snapshot: [TouchedFile]? = changed || force || visible ? tracker.log.files() : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.refreshing = false
                self.phase = .loaded
                if let snapshot, snapshot != self.files { self.apply(snapshot) }
            }
        }
    }

    private func apply(_ snapshot: [TouchedFile]) {
        files = snapshot
        if let selection, !snapshot.contains(where: { $0.path == selection }) { self.selection = nil }
        updateUnseen()
        syncPreview()
    }

    // MARK: 新文档提示

    private var createdDocuments: Set<String> {
        Set(files.filter { $0.isDocument && $0.action == .created }.map(\.path))
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
        guard !query.isEmpty else { return files }
        return files.filter { $0.relativePath(root: root).lowercased().contains(query) }
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
        if target == self.target, phase == .loaded { return completion(files) }
        model.locateTranscript(kind: target.kind, sessionID: sid) { [weak self] url in
            guard let url, let self else { return completion(nil) }
            self.queue.async {
                let tracker = TouchedFilesTracker(url: url, kind: target.kind, cwd: target.cwd)
                tracker.refresh()
                let files = tracker.log.files()
                DispatchQueue.main.async { completion(files) }
            }
        }
    }

    /// 语音助手 `open_file`：选中会话的最近一个文档（可按名字筛选）；没有文档时退回最近的任意文件。
    static func latestFile(in files: [TouchedFile], matching query: String?) -> TouchedFile? {
        let existing = files.filter(\.exists)
        let q = query?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let matched = q.isEmpty ? existing : existing.filter { $0.path.lowercased().contains(q) }
        let byTime = matched.sorted { ($0.lastTouched ?? .distantPast) > ($1.lastTouched ?? .distantPast) }
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
