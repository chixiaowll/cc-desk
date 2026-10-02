import AppKit
import Combine
import CCDeskCore

/// 状态中心。只在主线程访问；后台队列只做文件读取和子进程调用。
final class AppModel: ObservableObject {
    @Published private(set) var groups: [SessionGroup] = []
    @Published private(set) var now = Date()
    @Published var selectedID: String? {
        didSet { if let id = selectedID { clearUnread(id) } }
    }
    @Published var showNewSession = false
    /// 由 ContentView 在 onAppear 时注入，用于在窗口已关闭时重新打开（App 设计上关闭窗口不退出）。
    var openMainWindow: (() -> Void)?
    @Published var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedGroups") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsedGroups") }
    }
    @Published private(set) var recentDirs: [String] = UserDefaults.standard.stringArray(forKey: "recentDirs") ?? []
    /// 历史会话（不含当前运行中的），按时间倒序；后台每 30 秒刷新，打开历史弹出层 / 搜索面板时立即刷新。
    @Published private var historyEntries: [HistoryEntry] = []
    @Published var showHistoryPalette = false {
        didSet { if showHistoryPalette && !oldValue { refreshHistory() } }
    }
    /// 外部会话行 id -> 宿主 App 的 .app 路径（由进程链推出），用于显示真实 App 图标。
    private(set) var hostAppPaths: [String: String] = [:]

    let pool = TerminalPool()
    let notifier = Notifier()
    private let adapter = ClaudeAdapter()
    private let resolver = ProjectResolver(git: SystemProbe.git)
    private let queue = DispatchQueue(label: "cc-desk.poll")
    /// 只在 `queue` 上使用（非线程安全）。
    private let transcripts = TranscriptIndex()
    private var refreshingHistory = false
    /// 侧栏上已有对应行的 Claude sessionId（运行中的 + 内嵌终端里已结束、可原地恢复的）；
    /// 历史列表排除这些，并据此在主线程上再过滤一次（后台结果可能已过时）。
    private var liveSessionIDs: Set<String> = []
    private var timer: Timer?
    private var polling = false
    private var sessions: [AgentSession] = []
    private var lastStatuses: [String: AgentStatus]?
    private var missing: [WorkspaceEntry] = []
    /// 每个内嵌终端最近一次对应的 Claude sessionId，用于持久化恢复。
    private var knownSessionIDs: [UUID: String] = [:]
    /// 正在接管中的外部进程 pid，防止同一进程被重复接管。
    private var takingOver: Set<Int32> = []
    /// 曾经在某个内嵌终端里观测到过 Claude session 的终端 id；用于区分"claude 已退出留下普通 shell"
    /// 与"刚恢复、claude 还没来得及注册"两种情况。
    private var observedClaude: Set<UUID> = []
    /// 内嵌终端里 claude 已退出、终端仍留着 shell 时，最近一次的 sessionId 与退出时间；侧栏显示为「已结束」并可原地恢复。
    private var endedSessionIDs: [UUID: (id: String, at: Date)] = [:]
    /// 最近一次拿到的 transcript 标题，供刚结束的会话在后台尚未补齐标题时沿用。
    private var titleCache: [String: TranscriptMeta] = [:]
    /// 已发出原地恢复命令、claude 尚未注册的终端 -> 发出时间；期间隐藏恢复按钮，防止重复发送。
    @Published private var resumingEnded: [UUID: Date] = [:]
    /// 最近一次 poll 的进程表，供「激活 .other 宿主」时查找宿主 App。
    private var lastProcesses: ProcessTable?
    private var tick = 0
    /// 「测试通知与角标」期间暂时显示示例角标，到期后恢复真实计数。
    private var badgePreviewUntil: Date?
    /// 「已完成·未读」的行 id：Claude 完成一轮（working → idle）时用户没在看它。仅内存中保存。
    private var unreadKeys: Set<String> = []
    /// 最近一次 poll 的项目解析结果，供未读状态变化时立即重建侧栏。
    private var lastProjects: [String: ProjectRef] = [:]

    func testNotificationAndBadge() {
        badgePreviewUntil = Date().addingTimeInterval(5)
        notifier.setBadge(3)
        notifier.sendTest { allowed in
            guard !allowed else { return }
            let alert = NSAlert()
            alert.messageText = "通知已被关闭"
            alert.informativeText = "请在「系统设置 → 通知 → CC Desk」中允许通知，才能在会话需要批准时收到提醒。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: 生命周期

    func start() {
        notifier.onOpen = { [weak self] key in self?.openFromNotification(key) }
        notifier.setup()
        restore()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        poll()
        refreshHistory()
    }

    func poll() {
        guard !polling else { return }
        polling = true
        let cwds = pool.terminals.map(\.cwd) + missing.map(\.cwd)
        let endedIDs = endedSessionIDs.values.map(\.id)
        let resolver = self.resolver
        let transcripts = self.transcripts
        queue.async { [weak self] in
            let registry = RegistryReader.readAll()
            let processes = SystemProbe.processTable()
            var projects: [String: ProjectRef] = [:]
            for cwd in Set(registry.map(\.cwd) + cwds) { projects[cwd] = resolver.resolve(cwd) }
            var titles: [String: TranscriptMeta] = [:]
            for entry in registry where processes.isAlive(entry.pid) {
                if let meta = transcripts.meta(forSession: entry.sessionID) { titles[entry.sessionID] = meta }
            }
            for sid in endedIDs where titles[sid] == nil {
                if let meta = transcripts.meta(forSession: sid) { titles[sid] = meta }
            }
            DispatchQueue.main.async {
                self?.apply(registry: registry, processes: processes, projects: projects, titles: titles)
            }
        }
    }

    /// 在后台刷新历史会话列表；已在刷新中时忽略。
    func refreshHistory() {
        guard !refreshingHistory else { return }
        refreshingHistory = true
        let live = liveSessionIDs
        let resolver = self.resolver
        let transcripts = self.transcripts
        queue.async { [weak self] in
            let items = transcripts.history(excluding: live)
            let entries = items.map { item -> HistoryEntry in
                let root = resolver.resolve(item.cwd).root
                return HistoryEntry(item: item, root: root, projectTitle: HistoryEntry.projectTitle(root: root))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshingHistory = false
                self.historyEntries = entries
            }
        }
    }

    private func apply(registry: [RegistryEntry], processes: ProcessTable, projects: [String: ProjectRef],
                       titles: [String: TranscriptMeta]) {
        polling = false
        now = Date()
        lastProcesses = processes
        var built = SessionBuilder.build(registry: registry, processes: processes,
                                         embedded: pool.infos(processes: processes, ended: endedSessionIDs),
                                         missing: missing)
        if trackEmbeddedClaude(built) {
            // 本轮刚发现有 claude 退出：带上 endedSessionIDs 重建，避免先闪一下「终端」。
            built = SessionBuilder.build(registry: registry, processes: processes,
                                         embedded: pool.infos(processes: processes, ended: endedSessionIDs),
                                         missing: missing)
        }
        sessions = built
        let previousLive = liveSessionIDs
        liveSessionIDs = Set(sessions.compactMap(\.sessionID))
        for (sid, meta) in titles { titleCache[sid] = meta }
        titleCache = titleCache.filter { liveSessionIDs.contains($0.key) }
        var hostApps: [String: String] = [:]
        for s in sessions {
            if let path = HostApps.bundlePath(for: s, processes: processes) { hostApps[s.id] = path }
        }
        hostAppPaths = hostApps
        lastProjects = projects

        // 未读：会话消失或重新开始处理 / 等批准时清除；用户正看着选中的行时也清除。
        let appVisible = NSApp.isActive && NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        let statusByID = Dictionary(sessions.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        unreadKeys = unreadKeys.filter { key in
            guard let status = statusByID[key], status != .working, !status.isWaiting else { return false }
            return !(appVisible && key == selectedID)
        }
        rebuildGroups()

        let rows = groups.flatMap(\.rows)
        let events = TransitionDetector.events(previous: lastStatuses, rows: rows)
        lastStatuses = Dictionary(rows.map { ($0.id, $0.session.status) }, uniquingKeysWith: { a, _ in a })
        var newlyUnread = false
        for event in events where !(appVisible && event.sessionKey == selectedID) {
            notifier.post(event)
            if event.kind == .finished, unreadKeys.insert(event.sessionKey).inserted { newlyUnread = true }
        }
        if newlyUnread { rebuildGroups() }
        updateBadge()

        tick += 1
        if tick % 30 == 0 {
            saveWorkspace()
            refreshHistory()
        } else if !previousLive.subtracting(liveSessionIDs).isEmpty {
            // 有会话从侧栏消失（如关闭了已结束的终端）：立即刷新，让它回到历史列表。
            refreshHistory()
        }
    }

    /// 用最近一次 poll 的会话重建侧栏分组（带上当前的未读集合）。
    private func rebuildGroups() {
        let projects = lastProjects
        let unread = unreadKeys
        groups = SidebarBuilder.build(
            sessions: sessions,
            project: { projects[$0] ?? ProjectRef(root: $0, branch: nil, cwd: $0) },
            titles: { [titleCache] s in s.sessionID.flatMap { titleCache[$0] } },
            unread: { unread.contains($0.id) })
    }

    /// 清除某行的未读标记，并立即刷新侧栏与 Dock 角标。
    private func clearUnread(_ id: String) {
        guard unreadKeys.remove(id) != nil else { return }
        rebuildGroups()
        updateBadge()
    }

    /// Dock 角标 = 等批准数 + 已完成·未读数（不含同时在等批准的行）；为 0 时不显示。「测试通知与角标」期间不覆盖示例角标。
    private func updateBadge() {
        guard badgePreviewUntil.map({ $0 < Date() }) ?? true else { return }
        badgePreviewUntil = nil
        let waiting = groups.reduce(0) { $0 + $1.waitingCount }
        let unread = groups.reduce(0) { $0 + $1.unreadCount }
        let count = waiting + unread
        notifier.setBadge(count)
    }

    /// 根据本轮内嵌终端的状态更新 observedClaude / knownSessionIDs / endedSessionIDs。
    /// 返回 true 表示本轮新发现有 claude 退出。
    private func trackEmbeddedClaude(_ sessions: [AgentSession]) -> Bool {
        var newlyEnded = false
        for s in sessions {
            guard case .embedded(let tid) = s.host else { continue }
            if s.kind == .claude, s.status != .ended {
                observedClaude.insert(tid)
                if let sid = s.sessionID { knownSessionIDs[tid] = sid }
                endedSessionIDs[tid] = nil
                if resumingEnded[tid] != nil { resumingEnded[tid] = nil }
            } else if s.status == .unknown, observedClaude.contains(tid) {
                // claude 已退出，只留下普通 shell：记下它以便原地恢复；但忘掉旧 sessionId，
                // 下次启动 App 时不要再自动 resume。
                if let sid = knownSessionIDs[tid] {
                    endedSessionIDs[tid] = (id: sid, at: Date())
                    newlyEnded = true
                }
                knownSessionIDs[tid] = nil
            }
        }
        return newlyEnded
    }

    // MARK: 查询

    var selectedTerminalID: UUID? {
        guard let id = selectedID, id.hasPrefix("term:") else { return nil }
        return UUID(uuidString: String(id.dropFirst("term:".count)))
    }

    var selectedRow: SidebarRow? {
        groups.lazy.flatMap(\.rows).first { $0.id == self.selectedID }
    }

    /// 全部历史会话（排除运行中的），按时间倒序。
    var history: [HistoryEntry] {
        historyEntries.filter { !liveSessionIDs.contains($0.item.sessionID) }
    }

    /// 某个项目根目录下的历史会话，按时间倒序。
    func history(forRoot root: String) -> [HistoryEntry] {
        history.filter { $0.root == root }
    }

    private var embeddedRowsInOrder: [SidebarRow] {
        let rows = groups.flatMap(\.rows)
        return pool.terminals.compactMap { t in rows.first { $0.session.host == .embedded(terminalID: t.id) } }
    }

    // MARK: 动作

    func activate(_ row: SidebarRow) {
        clearUnread(row.id)
        switch row.session.host {
        case .embedded:
            selectedID = row.id
        case .terminalApp(let tty):
            if !Jumper.jumpToTerminalApp(tty: tty) {
                alertAutomationDenied()
            }
        case .vscode:
            Jumper.openInVSCode(cwd: row.session.cwd)
        case .other:
            if let pid = row.session.pid, let processes = lastProcesses,
               let appPath = HostApps.bundlePath(ofPID: pid, processes: processes) {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath),
                                                   configuration: NSWorkspace.OpenConfiguration())
            } else {
                alert("无法跳转", "这个 session 运行在不支持定位的终端中。可以右键「在这里接管」。")
            }
        case .missing:
            break
        }
    }

    /// 把键盘焦点还给当前选中的内嵌终端（如关闭历史面板后）。
    func focusSelectedTerminal() {
        guard let id = selectedTerminalID, let terminal = pool.terminal(id) else { return }
        terminal.view.window?.makeFirstResponder(terminal.view)
    }

    func selectEmbedded(index: Int) {
        let rows = embeddedRowsInOrder
        guard rows.indices.contains(index) else { return }
        selectedID = rows[index].id
    }

    func newSession(cwd rawCwd: String) {
        let cwd = ProjectResolver.canonical(rawCwd)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            alert("目录不存在", cwd)
            return
        }
        let terminal = makeTerminal(id: UUID(), cwd: cwd, command: adapter.launchCommand())
        selectedID = "term:\(terminal.id.uuidString)"
        rememberRecent(cwd)
        saveWorkspace()
        poll()
    }

    /// 已结束的内嵌会话：在同一个终端里执行 `claude --resume <id>` 并选中。
    func resumeEnded(_ row: SidebarRow) {
        guard case .embedded(let tid) = row.session.host, row.session.status == .ended,
              let sid = row.session.sessionID, let terminal = pool.terminal(tid) else { return }
        selectedID = row.id
        guard !isResumingEnded(row) else { return }
        resumingEnded[tid] = Date()
        terminal.send(text: adapter.resumeCommand(sessionID: sid), submit: true)
        terminal.view.window?.makeFirstResponder(terminal.view)
    }

    /// 刚发出恢复命令（10 秒内）且 claude 还没注册。
    func isResumingEnded(_ row: SidebarRow) -> Bool {
        guard let tid = row.session.host.terminalID, let at = resumingEnded[tid] else { return false }
        return Date().timeIntervalSince(at) < 10
    }

    func close(_ row: SidebarRow) {
        guard case .embedded(let tid) = row.session.host, let terminal = pool.terminal(tid) else { return }
        if row.session.status.isActive,
           !confirm("关闭「\(row.displayName)」？", "它还在\(row.session.status.label)，关闭会中断当前这一轮。") { return }
        terminal.terminate()
        removeTerminal(tid)
    }

    func closeSelected() {
        if let row = selectedRow { close(row) }
    }

    func killExternal(_ row: SidebarRow) {
        guard let pid = row.session.pid, !row.session.host.isEmbedded else { return }
        guard confirm("结束「\(row.displayName)」？", "将向进程 \(pid) 发送 SIGTERM。") else { return }
        kill(pid, SIGTERM)
        poll()
    }

    func isTakingOver(_ row: SidebarRow) -> Bool {
        guard let pid = row.session.pid else { return false }
        return takingOver.contains(pid)
    }

    func takeOver(_ row: SidebarRow) {
        guard let pid = row.session.pid, let sid = row.session.sessionID, !row.session.host.isEmbedded else { return }
        guard !takingOver.contains(pid) else { return }
        if row.session.status.isActive,
           !confirm("接管「\(row.displayName)」？", "它还在\(row.session.status.label)，接管会先结束外部进程，中断当前这一轮。") { return }
        let cwd = ProjectResolver.canonical(row.session.cwd)
        guard FileManager.default.fileExists(atPath: cwd) else {
            alert("目录不存在", cwd)
            return
        }
        takingOver.insert(pid)
        kill(pid, SIGTERM)
        DispatchQueue.global().async { [weak self] in
            var alive = true
            for _ in 0..<50 {
                if kill(pid, 0) != 0 { alive = false; break }
                usleep(100_000)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.takingOver.remove(pid)
                if alive {
                    self.alert("外部进程没有退出", "进程 \(pid) 在 5 秒内没有结束，请手动处理后重试。")
                    return
                }
                let terminal = self.makeTerminal(id: UUID(), cwd: cwd, command: self.adapter.resumeCommand(sessionID: sid))
                self.knownSessionIDs[terminal.id] = sid
                self.selectedID = "term:\(terminal.id.uuidString)"
                self.saveWorkspace()
                self.poll()
            }
        }
    }

    func copyResumeCommand(_ row: SidebarRow) {
        guard let sid = row.session.sessionID else { return }
        let command = "cd \(ShellQuote.quote(row.session.cwd)) && \(adapter.resumeCommand(sessionID: sid))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func revealInFinder(_ row: SidebarRow) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.session.cwd)])
    }

    func relocateMissing(_ row: SidebarRow) {
        guard case .missing(let tid) = row.session.host,
              let entry = missing.first(where: { $0.terminalID == tid }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "为「\(entry.name)」选择新的目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let cwd = ProjectResolver.canonical(url.path)
        missing.removeAll { $0.terminalID == tid }
        // Claude 按目录保存会话，换目录后无法 resume 原会话，改为新开。
        let terminal = makeTerminal(id: tid, cwd: cwd, command: adapter.launchCommand())
        selectedID = "term:\(terminal.id.uuidString)"
        saveWorkspace()
        poll()
    }

    func removeMissing(_ row: SidebarRow) {
        guard case .missing(let tid) = row.session.host else { return }
        missing.removeAll { $0.terminalID == tid }
        saveWorkspace()
        poll()
    }

    /// 在历史会话的原目录新建内嵌终端执行 `claude --resume <id>` 并选中；已在运行则直接跳过去。
    func resumeHistory(_ item: HistoryItem) {
        if let row = groups.lazy.flatMap(\.rows).first(where: { $0.session.sessionID == item.sessionID }) {
            if row.session.status == .ended { resumeEnded(row) } else { activate(row) }
            return
        }
        let cwd = ProjectResolver.canonical(item.cwd)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            alert("目录不存在", cwd)
            return
        }
        let terminal = makeTerminal(id: UUID(), cwd: cwd, command: adapter.resumeCommand(sessionID: item.sessionID))
        knownSessionIDs[terminal.id] = item.sessionID
        liveSessionIDs.insert(item.sessionID)
        selectedID = "term:\(terminal.id.uuidString)"
        rememberRecent(cwd)
        saveWorkspace()
        poll()
    }

    func chooseDirectoryAndCreate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择要启动 Claude Code 的目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        showNewSession = false
        newSession(cwd: url.path)
    }

    // MARK: 退出与恢复

    /// 返回 true 表示可以退出。
    func confirmQuit() -> Bool {
        let active = sessions.filter { $0.host.isEmbedded && $0.status.isActive }
        if !active.isEmpty {
            let names = active.map { $0.name.isEmpty ? $0.cwd : $0.name }.joined(separator: "、")
            guard confirm("还有 \(active.count) 个 session 在运行", "\(names)\n退出会中断它们，下次打开时会自动恢复对话。") else {
                return false
            }
        }
        saveWorkspace()
        return true
    }

    func saveWorkspace() {
        let embedded = pool.terminals.map { terminal -> WorkspaceEntry in
            let cwd = ProjectResolver.canonical(terminal.cwd)
            let sessionID = knownSessionIDs[terminal.id]
            return WorkspaceEntry(terminalID: terminal.id, cwd: cwd, sessionID: sessionID,
                                  name: terminal.title, kind: sessionID != nil ? .claude : nil)
        }
        try? WorkspaceStore.save(WorkspaceFile(entries: embedded + missing))
    }

    private func restore() {
        guard let file = WorkspaceStore.load() else { return }
        for rawEntry in file.entries {
            var entry = rawEntry
            entry.cwd = ProjectResolver.canonical(entry.cwd)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: entry.cwd, isDirectory: &isDir), isDir.boolValue {
                let command = entry.sessionID != nil ? adapter.resumeCommand(sessionID: entry.sessionID!) : nil
                makeTerminal(id: entry.terminalID, cwd: entry.cwd, command: command)
                if let sid = entry.sessionID { knownSessionIDs[entry.terminalID] = sid }
            } else {
                missing.append(entry)
            }
        }
        if let first = pool.terminals.first { selectedID = "term:\(first.id.uuidString)" }
    }

    // MARK: 内部

    @discardableResult
    private func makeTerminal(id: UUID, cwd: String, command: String?) -> EmbeddedTerminal {
        let title = URL(fileURLWithPath: cwd).lastPathComponent
        let terminal = pool.create(id: id, cwd: cwd, title: title, command: command)
        terminal.onTerminated = { [weak self] tid in self?.removeTerminal(tid) }
        return terminal
    }

    private func removeTerminal(_ tid: UUID) {
        pool.remove(tid)
        knownSessionIDs[tid] = nil
        observedClaude.remove(tid)
        endedSessionIDs[tid] = nil
        resumingEnded[tid] = nil
        if selectedTerminalID == tid { selectedID = nil }
        saveWorkspace()
        poll()
    }

    private func rememberRecent(_ rawCwd: String) {
        let cwd = ProjectResolver.canonical(rawCwd)
        recentDirs = [cwd] + recentDirs.filter { $0 != cwd }.prefix(9)
        UserDefaults.standard.set(recentDirs, forKey: "recentDirs")
    }

    private func openFromNotification(_ key: String) {
        NSApp.activate(ignoringOtherApps: true)
        openMainWindow?()
        if let row = groups.lazy.flatMap(\.rows).first(where: { $0.id == key }) { activate(row) }
    }

    private func confirm(_ title: String, _ info: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func alert(_ title: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.runModal()
    }

    private func alertAutomationDenied() {
        let alert = NSAlert()
        alert.messageText = "无法跳转到 Terminal"
        alert.informativeText = "请在「系统设置 → 隐私与安全性 → 自动化」中允许 CC Desk 控制 Terminal，或该标签已关闭。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 历史会话 + 其所属项目（用于按目录筛选与显示目录标签）。
struct HistoryEntry: Identifiable, Equatable {
    let item: HistoryItem
    let root: String
    let projectTitle: String
    var id: String { item.id }

    static func projectTitle(root: String) -> String {
        if root == NSHomeDirectory() { return "~" }
        let name = URL(fileURLWithPath: root).lastPathComponent
        return name.isEmpty ? root : name
    }
}
