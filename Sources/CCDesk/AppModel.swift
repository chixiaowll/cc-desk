import AppKit
import Combine
import CCDeskCore

/// 状态中心。只在主线程访问；后台队列只做文件读取和子进程调用。
final class AppModel: ObservableObject {
    @Published private(set) var groups: [SessionGroup] = []
    @Published private(set) var now = Date()
    @Published var selectedID: String?
    @Published var showNewSession = false
    /// 由 ContentView 在 onAppear 时注入，用于在窗口已关闭时重新打开（App 设计上关闭窗口不退出）。
    var openMainWindow: (() -> Void)?
    @Published var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedGroups") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsedGroups") }
    }
    @Published private(set) var recentDirs: [String] = UserDefaults.standard.stringArray(forKey: "recentDirs") ?? []

    let pool = TerminalPool()
    let notifier = Notifier()
    private let adapter = ClaudeAdapter()
    private let resolver = ProjectResolver(git: SystemProbe.git)
    private let queue = DispatchQueue(label: "cc-desk.poll")
    private var timer: Timer?
    private var polling = false
    private var sessions: [AgentSession] = []
    private var lastStatuses: [String: AgentStatus]?
    private var missing: [WorkspaceEntry] = []
    /// 每个内嵌终端最近一次对应的 Claude sessionId，用于持久化恢复。
    private var knownSessionIDs: [UUID: String] = [:]
    /// 正在接管中的外部进程 pid，防止同一进程被重复接管。
    private var takingOver: Set<Int32> = []
    private var tick = 0

    // MARK: 生命周期

    func start() {
        notifier.onOpen = { [weak self] key in self?.openFromNotification(key) }
        notifier.setup()
        restore()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func poll() {
        guard !polling else { return }
        polling = true
        let cwds = pool.terminals.map(\.cwd) + missing.map(\.cwd)
        let resolver = self.resolver
        queue.async { [weak self] in
            let registry = RegistryReader.readAll()
            let processes = SystemProbe.processTable()
            var projects: [String: ProjectRef] = [:]
            for cwd in Set(registry.map(\.cwd) + cwds) { projects[cwd] = resolver.resolve(cwd) }
            DispatchQueue.main.async {
                self?.apply(registry: registry, processes: processes, projects: projects)
            }
        }
    }

    private func apply(registry: [RegistryEntry], processes: ProcessTable, projects: [String: ProjectRef]) {
        polling = false
        now = Date()
        sessions = SessionBuilder.build(registry: registry, processes: processes,
                                        embedded: pool.infos(processes: processes), missing: missing)
        for s in sessions {
            if case .embedded(let tid) = s.host, let sid = s.sessionID { knownSessionIDs[tid] = sid }
        }
        groups = SidebarBuilder.build(sessions: sessions) { projects[$0] ?? ProjectRef(root: $0, branch: nil, cwd: $0) }

        let rows = groups.flatMap(\.rows)
        let events = TransitionDetector.events(previous: lastStatuses, rows: rows)
        lastStatuses = Dictionary(rows.map { ($0.id, $0.session.status) }, uniquingKeysWith: { a, _ in a })
        let appVisible = NSApp.isActive && NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        for event in events where !(appVisible && event.sessionKey == selectedID) {
            notifier.post(event)
        }
        let waiting = rows.filter { $0.session.status.isWaiting }.count
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil

        tick += 1
        if tick % 30 == 0 { saveWorkspace() }
    }

    // MARK: 查询

    var selectedTerminalID: UUID? {
        guard let id = selectedID, id.hasPrefix("term:") else { return nil }
        return UUID(uuidString: String(id.dropFirst("term:".count)))
    }

    var selectedRow: SidebarRow? {
        groups.lazy.flatMap(\.rows).first { $0.id == self.selectedID }
    }

    private var embeddedRowsInOrder: [SidebarRow] {
        let rows = groups.flatMap(\.rows)
        return pool.terminals.compactMap { t in rows.first { $0.session.host == .embedded(terminalID: t.id) } }
    }

    // MARK: 动作

    func activate(_ row: SidebarRow) {
        switch row.session.host {
        case .embedded:
            selectedID = row.id
        case .terminalApp(let tty):
            if !Jumper.jumpToTerminalApp(tty: tty) {
                alert("无法跳转到 Terminal",
                      "请在「系统设置 → 隐私与安全性 → 自动化」中允许 CC Desk 控制 Terminal，或该标签已关闭。")
            }
        case .vscode:
            Jumper.openInVSCode(cwd: row.session.cwd)
        case .other:
            alert("无法跳转", "这个 session 运行在不支持定位的终端中。可以右键「在这里接管」。")
        case .missing:
            break
        }
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
}
