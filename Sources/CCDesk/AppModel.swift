import AppKit
import Combine
import CCDeskCore

/// 状态中心。只在主线程访问；后台队列只做文件读取和子进程调用。
final class AppModel: ObservableObject {
    @Published private(set) var groups: [SessionGroup] = []
    @Published private(set) var now = Date()
    @Published var selectedID: String? {
        didSet {
            if let id = selectedID { clearUnread(id) }
            // 对话模式只作用于选中的内嵌 session；没有选中内嵌 session 时自动关闭。
            if selectedTerminalID == nil { conversation.turnOff() }
        }
    }
    @Published var showNewSession = false
    /// 由 ContentView 在 onAppear 时注入，用于在窗口已关闭时重新打开（App 设计上关闭窗口不退出）。
    var openMainWindow: (() -> Void)?
    @Published var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedGroups") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsedGroups") }
    }
    /// 新建会话默认使用的 agent（上次使用的）；只会记住可启动的种类。
    @Published private(set) var lastAgent: AgentKind = {
        let stored = UserDefaults.standard.string(forKey: "lastAgent").flatMap(AgentKind.init(rawValue:))
        return stored.flatMap { AgentAdapters.adapter(for: $0) != nil ? $0 : nil } ?? .claude
    }()
    /// 本机检测到的 codex / pi；nil 表示尚未检测完成。
    @Published private(set) var installedAgents: Set<AgentKind>?
    private var probingAgents = false
    private var agentsProbedAt: Date?
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
    /// 语音输入（按住右 ⌥ / 麦克风按钮，本机 Whisper 识别后插入选中的内嵌终端）。
    private(set) lazy var voice = VoiceInput(
        pool: pool,
        selectedTerminalID: { [weak self] in self?.selectedTerminalID },
        canListen: { [weak self] in self?.canListenForVoice ?? false })
    /// 对话模式（免按键：唤醒词 + 持续监听，语音指令发送 / 清空 / 批准）。开启时忽略按住说话。
    private(set) lazy var conversation = ConversationMode(
        pool: pool, voice: voice,
        selectedTerminalID: { [weak self] in self?.selectedTerminalID },
        statusOf: { [weak self] tid in self?.status(ofTerminal: tid) })
    private let resolver = ProjectResolver(git: SystemProbe.git)
    private let queue = DispatchQueue(label: "cc-desk.poll")
    /// 只在 `queue` 上使用（非线程安全）。
    private let transcripts = TranscriptIndex()
    /// Codex / pi 会话文件索引；只在 `queue` 上使用。
    private let agentIndex = AgentSessionIndex()
    /// pid -> (启动时间, cwd) 缓存；只在 `queue` 上使用。
    private var processDetails: [Int32: ProcessDetails] = [:]
    /// Claude 套餐与用量（来自 Claude Code 写在 ~/.claude.json 的缓存，只读）；nil 时不显示。
    @Published private(set) var claudeUsage: ClaudeUsage?
    /// 只在 `queue` 上使用；文件 mtime 未变时不重新解析。
    private let usageSource = ClaudeUsageSource()
    private var refreshingUsage = false
    @Published var showIntegrations = false {
        didSet { if showIntegrations && !oldValue { refreshIntegrations() } }
    }
    /// Codex / pi 状态集成的安装状态；nil 键表示尚未检测。
    @Published private(set) var integrationStatus: [AgentKind: IntegrationStatus] = [:]
    /// 正在安装 / 卸载的集成。
    @Published private(set) var integrationBusy: Set<AgentKind> = []
    private var refreshingHistory = false
    /// 侧栏上已有对应行的 Claude sessionId（运行中的 + 内嵌终端里已结束、可原地恢复的）；
    /// 历史列表排除这些，并据此在主线程上再过滤一次（后台结果可能已过时）。
    private var liveSessionIDs: Set<String> = []
    private var timer: Timer?
    private var polling = false
    private var sessions: [AgentSession] = []
    private var lastStatuses: [String: AgentStatus]?
    private var missing: [WorkspaceEntry] = []
    /// 每个内嵌终端最近一次对应的 agent sessionId 及其种类，用于持久化恢复。
    private var knownSessionIDs: [UUID: String] = [:]
    private var knownKinds: [UUID: AgentKind] = [:]
    /// 正在接管中的外部进程 pid，防止同一进程被重复接管。
    private var takingOver: Set<Int32> = []
    /// 曾经在某个内嵌终端里观测到过 agent 会话的终端 id；用于区分"agent 已退出留下普通 shell"
    /// 与"刚恢复、agent 还没来得及注册"两种情况。
    private var observedAgent: Set<UUID> = []
    /// 内嵌终端里 agent 已退出、终端仍留着 shell 时，最近一次的 sessionId、种类与退出时间；侧栏显示为「已结束」并可原地恢复。
    private var endedSessionIDs: [UUID: EndedSession] = [:]
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
            alert.messageText = L("alert.notificationsOff.title")
            alert.informativeText = L("alert.notificationsOff.message")
            alert.addButton(withTitle: L("action.openSystemSettings"))
            alert.addButton(withTitle: L("action.cancel"))
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: 生命周期

    func start() {
        conversation.host = self
        notifier.onOpen = { [weak self] key in self?.openFromNotification(key) }
        notifier.setup()
        restore()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        poll()
        refreshHistory()
        refreshUsage()
        voice.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.conversation.autoStartIfEnabled() }
    }

    /// 只在主窗口为 key、且没有弹出表单 / 历史面板 / 面板窗口时响应右 ⌥。
    private var canListenForVoice: Bool {
        guard NSApp.isActive, let window = NSApp.keyWindow, !(window is NSPanel),
              window.attachedSheet == nil else { return false }
        return !showNewSession && !showHistoryPalette && !conversation.isOn
    }

    func poll() {
        guard !polling else { return }
        polling = true
        let cwds = pool.terminals.map(\.cwd) + missing.map(\.cwd)
        let ended = endedSessionIDs.values.map { ($0.id, $0.kind) }
        // 内嵌终端 shell pid -> 预期运行的 agent 会话（恢复 / 接管时发出的命令），供后台在其他来源缺失时兜底。
        var expected: [Int32: (kind: AgentKind, sessionID: String)] = [:]
        for terminal in pool.terminals {
            if let kind = knownKinds[terminal.id], kind != .claude, let sid = knownSessionIDs[terminal.id] {
                expected[terminal.shellPID] = (kind, sid)
            }
        }
        let resolver = self.resolver
        let transcripts = self.transcripts
        let agentIndex = self.agentIndex
        queue.async { [weak self] in
            guard let self else { return }
            let registry = RegistryReader.readAll()
            let processes = SystemProbe.processTable()
            let hooks = HookStateReader.readAll()
            var fallback: [String: (kind: AgentKind, sessionID: String)] = [:]
            for (shellPID, value) in expected {
                if let tty = processes.tty(of: shellPID) { fallback[tty] = value }
            }
            let agents = AgentResolver.resolve(processes: processes, details: { pid in
                let d = self.details(pid: pid)
                return (d?.cwd, d?.startedAt)
            }, hooks: hooks, index: agentIndex, fallbackSessions: fallback)
            var projects: [String: ProjectRef] = [:]
            for cwd in Set(registry.map(\.cwd) + agents.map(\.cwd) + cwds) { projects[cwd] = resolver.resolve(cwd) }
            var titles: [String: TranscriptMeta] = [:]
            for entry in registry where processes.isAlive(entry.pid) {
                if let meta = transcripts.meta(forSession: entry.sessionID) { titles[entry.sessionID] = meta }
            }
            for agent in agents {
                guard let sid = agent.sessionID else { continue }
                let path = agent.sessionPath ?? agentIndex.locate(kind: agent.kind, sessionID: sid)
                if let path, let meta = agentIndex.meta(path: path, kind: agent.kind) { titles[sid] = meta }
            }
            for (sid, kind) in ended where titles[sid] == nil {
                let meta: TranscriptMeta?
                if kind == .claude {
                    meta = transcripts.meta(forSession: sid)
                } else {
                    meta = agentIndex.locate(kind: kind, sessionID: sid).flatMap { agentIndex.meta(path: $0, kind: kind) }
                }
                if let meta { titles[sid] = meta }
            }
            DispatchQueue.main.async { [weak self] in
                self?.apply(registry: registry, processes: processes, agents: agents, projects: projects, titles: titles)
            }
        }
    }

    /// 进程启动时间与 cwd，按 (pid, 启动时间) 缓存；只在 `queue` 上调用。
    private func details(pid: Int32) -> ProcessDetails? {
        guard let fresh = SystemProbe.processDetails(pid: pid, includeCwd: false) else {
            processDetails[pid] = nil
            return nil
        }
        if let cached = processDetails[pid], cached.startedAt == fresh.startedAt, cached.cwd != nil { return cached }
        let full = SystemProbe.processDetails(pid: pid, includeCwd: true)
        processDetails[pid] = full
        return full
    }

    /// 在后台刷新历史会话列表；已在刷新中时忽略。
    func refreshHistory() {
        guard !refreshingHistory else { return }
        refreshingHistory = true
        let live = liveSessionIDs
        let resolver = self.resolver
        let transcripts = self.transcripts
        queue.async { [weak self] in
            guard let self else { return }
            let items = (transcripts.history(excluding: live) + self.agentIndex.history(excluding: live))
                .sorted { $0.modifiedAt > $1.modifiedAt }
            let entries = items.map { item -> HistoryEntry in
                let root = resolver.resolve(item.cwd).root
                return HistoryEntry(item: item, root: root, projectTitle: HistoryEntry.projectTitle(root: root))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshingHistory = false
                self.historyEntries = entries
            }
        }
    }

    /// 在后台读取 ~/.claude.json 的用量缓存（最多每 30 秒一次，mtime 未变时不解析）；跨过 90% 时每个重置周期提醒一次。
    func refreshUsage() {
        guard !refreshingUsage else { return }
        refreshingUsage = true
        let source = usageSource
        queue.async { [weak self] in
            let usage = source.read()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshingUsage = false
                if self.claudeUsage != usage { self.claudeUsage = usage }
                if let usage { self.postUsageAlerts(usage) }
            }
        }
    }

    private static let usageAlertsKey = "usageAlertsNotified"

    private func postUsageAlerts(_ usage: ClaudeUsage) {
        var notified = UserDefaults.standard.dictionary(forKey: Self.usageAlertsKey) as? [String: Double] ?? [:]
        let alerts = UsageAlerts.pending(usage: usage, lastNotified: notified, now: Date(), calendar: .current)
        guard !alerts.isEmpty else { return }
        for alert in alerts {
            notifier.post(alert)
            notified[alert.limitID] = alert.periodKey
        }
        UserDefaults.standard.set(notified, forKey: Self.usageAlertsKey)
    }

    private func apply(registry: [RegistryEntry], processes: ProcessTable, agents snapshots: [AgentProcessSnapshot],
                       projects: [String: ProjectRef], titles: [String: TranscriptMeta]) {
        polling = false
        now = Date()
        lastProcesses = processes
        let agents = mergeAgentStatus(snapshots, processes: processes)
        var built = SessionBuilder.build(registry: registry, processes: processes,
                                         embedded: pool.infos(processes: processes, ended: endedSessionIDs),
                                         missing: missing, agents: agents)
        if trackEmbeddedAgents(built) {
            // 本轮刚发现有 agent 退出：带上 endedSessionIDs 重建，避免先闪一下「终端」。
            built = SessionBuilder.build(registry: registry, processes: processes,
                                         embedded: pool.infos(processes: processes, ended: endedSessionIDs),
                                         missing: missing, agents: agents)
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
        conversation.observe(terminalID: selectedTerminalID,
                             status: selectedTerminalID.flatMap { status(ofTerminal: $0) })

        tick += 1
        if tick % 600 == 1 { queue.async { HookStateReader.prune() } }
        if tick % 30 == 0 {
            saveWorkspace()
            refreshHistory()
            refreshUsage()
        } else if !previousLive.subtracting(liveSessionIDs).isEmpty {
            // 有会话从侧栏消失（如关闭了已结束的终端）：立即刷新，让它回到历史列表。
            refreshHistory()
        }
    }

    /// Codex / pi：hook 状态 + 内嵌终端的屏幕规则状态按 §4.2 合并；同时告诉各内嵌终端是否需要做屏幕检测。
    private func mergeAgentStatus(_ snapshots: [AgentProcessSnapshot], processes: ProcessTable) -> [AgentProcessInfo] {
        var detecting: [UUID: AgentKind] = [:]
        let infos = snapshots.map { snap -> AgentProcessInfo in
            var screen: StatusObservation?
            if let tty = snap.tty, let terminal = pool.terminal(tty: tty, processes: processes) {
                detecting[terminal.id] = snap.kind
                if terminal.detectionKind == snap.kind { screen = terminal.screenStatus }
            }
            let merged = AgentResolver.status(hook: snap.hook, screen: screen, startedAt: snap.startedAt, now: now)
            return AgentProcessInfo(pid: snap.pid, kind: snap.kind, tty: snap.tty, cwd: snap.cwd,
                                    sessionID: snap.sessionID, status: merged.status, statusChangedAt: merged.at)
        }
        for terminal in pool.terminals { terminal.detectionKind = detecting[terminal.id] }
        return infos
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

    /// 根据本轮内嵌终端的状态更新 observedAgent / knownSessionIDs / endedSessionIDs。
    /// 返回 true 表示本轮新发现有 agent 退出。
    private func trackEmbeddedAgents(_ sessions: [AgentSession]) -> Bool {
        var newlyEnded = false
        for s in sessions {
            guard case .embedded(let tid) = s.host else { continue }
            if s.kind.isAgent, s.status != .ended {
                observedAgent.insert(tid)
                // 换了一种 agent：旧 sessionId 不再适用。
                if knownKinds[tid] != s.kind { knownSessionIDs[tid] = nil }
                knownKinds[tid] = s.kind
                if let sid = s.sessionID { knownSessionIDs[tid] = sid }
                endedSessionIDs[tid] = nil
                if resumingEnded[tid] != nil { resumingEnded[tid] = nil }
            } else if s.kind == .other, s.status == .unknown, observedAgent.contains(tid) {
                // agent 已退出，只留下普通 shell：记下它以便原地恢复；但忘掉旧 sessionId，
                // 下次启动 App 时不要再自动 resume。
                if let sid = knownSessionIDs[tid] {
                    endedSessionIDs[tid] = EndedSession(id: sid, kind: knownKinds[tid] ?? .claude, at: Date())
                    newlyEnded = true
                }
                knownSessionIDs[tid] = nil
                knownKinds[tid] = nil
                observedAgent.remove(tid)
            }
        }
        return newlyEnded
    }

    // MARK: 查询

    /// 会话行 / 历史行是否显示 agent 名：规则集中在 `AgentLabelPolicy`。
    var showAgentLabel: Bool {
        let kinds = Set(sessions.map(\.kind).filter(\.isAgent)).union(historyEntries.map(\.item.kind))
        return AgentLabelPolicy.shows(presentKinds: kinds)
    }

    var selectedTerminalID: UUID? {
        guard let id = selectedID, id.hasPrefix("term:") else { return nil }
        return UUID(uuidString: String(id.dropFirst("term:".count)))
    }

    /// 某个内嵌终端对应行的当前状态。
    func status(ofTerminal tid: UUID) -> AgentStatus? {
        groups.lazy.flatMap(\.rows).first { $0.session.host == .embedded(terminalID: tid) }?.session.status
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
                alert(L("alert.cannotJump.title"), L("alert.cannotJump.message"))
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

    func availability(of kind: AgentKind) -> AgentAvailability {
        AgentAvailability.of(kind, installed: installedAgents)
    }

    /// 在后台检测 codex / pi 是否安装（新建面板打开、目录行操作出现时调用）；30 秒内不重复检测。
    func probeAgents() {
        guard !probingAgents else { return }
        if let at = agentsProbedAt, Date().timeIntervalSince(at) < 30 { return }
        probingAgents = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = SystemProbe.installedAgents()
            DispatchQueue.main.async {
                guard let self else { return }
                self.probingAgents = false
                self.agentsProbedAt = Date()
                self.installedAgents = found
            }
        }
    }

    /// 用 `kind`（默认上次使用的 agent）在目录中新建内嵌会话。
    func newSession(cwd rawCwd: String, kind: AgentKind? = nil) {
        let kind = kind ?? lastAgent
        guard let launcher = AgentAdapters.adapter(for: kind) else {
            alert(L("alert.cannotCreate.title"), L("alert.cannotCreate.message"))
            return
        }
        let cwd = ProjectResolver.canonical(rawCwd)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            alert(L("alert.directoryMissing.title"), cwd)
            return
        }
        if availability(of: kind) == .notInstalled {
            alert(L("alert.agentNotFound.title", kind.displayName), L("alert.agentNotFound.message", launcher.launchCommand()))
            return
        }
        if lastAgent != kind {
            lastAgent = kind
            UserDefaults.standard.set(kind.rawValue, forKey: "lastAgent")
        }
        let terminal = makeTerminal(id: UUID(), cwd: cwd, command: launcher.launchCommand())
        knownKinds[terminal.id] = kind
        selectedID = "term:\(terminal.id.uuidString)"
        rememberRecent(cwd)
        saveWorkspace()
        poll()
    }

    /// 已结束的内嵌会话：在同一个终端里执行对应 agent 的恢复命令（如 `codex resume <id>`）并选中。
    func resumeEnded(_ row: SidebarRow) {
        guard case .embedded(let tid) = row.session.host, row.session.status == .ended,
              let sid = row.session.sessionID, let terminal = pool.terminal(tid),
              let adapter = AgentAdapters.adapter(for: row.session.kind) else { return }
        selectedID = row.id
        guard !isResumingEnded(row) else { return }
        resumingEnded[tid] = Date()
        terminal.send(text: adapter.resumeCommand(sessionID: sid), submit: true)
        terminal.view.window?.makeFirstResponder(terminal.view)
    }

    /// 刚发出恢复命令（10 秒内）且 agent 还没出现。
    func isResumingEnded(_ row: SidebarRow) -> Bool {
        guard let tid = row.session.host.terminalID, let at = resumingEnded[tid] else { return false }
        return Date().timeIntervalSince(at) < 10
    }

    func close(_ row: SidebarRow) {
        guard case .embedded(let tid) = row.session.host, let terminal = pool.terminal(tid) else { return }
        if row.session.status.isActive,
           !confirm(L("confirm.close.title", row.displayName), L("confirm.close.message", row.session.status.label)) { return }
        terminal.terminate()
        removeTerminal(tid)
    }

    /// 不再确认、直接关闭内嵌会话（语音已确认过）。关闭的是选中的会话时先选中另一个内嵌会话，对话模式得以继续。
    func closeWithoutConfirmation(_ row: SidebarRow) {
        guard case .embedded(let tid) = row.session.host, let terminal = pool.terminal(tid) else { return }
        if selectedID == row.id, let next = embeddedRowsInOrder.first(where: { $0.id != row.id }) {
            selectedID = next.id
        }
        terminal.terminate()
        removeTerminal(tid)
    }

    func closeSelected() {
        if let row = selectedRow { close(row) }
    }

    func killExternal(_ row: SidebarRow) {
        guard let pid = row.session.pid, !row.session.host.isEmbedded else { return }
        guard confirm(L("confirm.kill.title", row.displayName), L("confirm.kill.message", Int(pid))) else { return }
        kill(pid, SIGTERM)
        poll()
    }

    func isTakingOver(_ row: SidebarRow) -> Bool {
        guard let pid = row.session.pid else { return false }
        return takingOver.contains(pid)
    }

    func canTakeOver(_ row: SidebarRow) -> Bool {
        row.session.pid != nil && row.session.sessionID != nil && !row.session.host.isEmbedded
            && AgentAdapters.adapter(for: row.session.kind) != nil
    }

    /// confirmed：调用方已确认过（如语音助手），忙碌时不再弹确认框。
    func takeOver(_ row: SidebarRow, confirmed: Bool = false) {
        guard let pid = row.session.pid, let sid = row.session.sessionID, !row.session.host.isEmbedded,
              let adapter = AgentAdapters.adapter(for: row.session.kind) else { return }
        let kind = row.session.kind
        guard !takingOver.contains(pid) else { return }
        if !confirmed, row.session.status.isActive,
           !confirm(L("confirm.takeOver.title", row.displayName), L("confirm.takeOver.message", row.session.status.label)) { return }
        let cwd = ProjectResolver.canonical(row.session.cwd)
        guard FileManager.default.fileExists(atPath: cwd) else {
            alert(L("alert.directoryMissing.title"), cwd)
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
                    self.alert(L("alert.processStillRunning.title"), L("alert.processStillRunning.message", Int(pid)))
                    return
                }
                let terminal = self.makeTerminal(id: UUID(), cwd: cwd, command: adapter.resumeCommand(sessionID: sid))
                self.remember(terminal.id, sessionID: sid, kind: kind)
                self.selectedID = "term:\(terminal.id.uuidString)"
                self.saveWorkspace()
                self.poll()
            }
        }
    }

    func copyResumeCommand(_ row: SidebarRow) {
        guard let sid = row.session.sessionID, let adapter = AgentAdapters.adapter(for: row.session.kind) else { return }
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
        panel.message = L("panel.relocate.message", entry.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let cwd = ProjectResolver.canonical(url.path)
        missing.removeAll { $0.terminalID == tid }
        // agent 按目录保存 / 查找会话，换目录后无法 resume 原会话，改为新开。
        let kind = entry.kind.flatMap { $0.isAgent ? $0 : nil } ?? .claude
        let terminal = makeTerminal(id: tid, cwd: cwd, command: AgentAdapters.adapter(for: kind)?.launchCommand())
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

    /// 在历史会话的原目录新建内嵌终端执行对应 agent 的恢复命令并选中；已在运行则直接跳过去。
    func resumeHistory(_ item: HistoryItem) {
        guard let adapter = AgentAdapters.adapter(for: item.kind) else { return }
        if let row = groups.lazy.flatMap(\.rows).first(where: { $0.session.sessionID == item.sessionID }) {
            if row.session.status == .ended { resumeEnded(row) } else { activate(row) }
            return
        }
        let cwd = ProjectResolver.canonical(item.cwd)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            alert(L("alert.directoryMissing.title"), cwd)
            return
        }
        let terminal = makeTerminal(id: UUID(), cwd: cwd, command: adapter.resumeCommand(sessionID: item.sessionID))
        remember(terminal.id, sessionID: item.sessionID, kind: item.kind)
        liveSessionIDs.insert(item.sessionID)
        selectedID = "term:\(terminal.id.uuidString)"
        rememberRecent(cwd)
        saveWorkspace()
        poll()
    }

    func chooseDirectoryAndCreate(kind: AgentKind? = nil) {
        let kind = kind ?? lastAgent
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = L("panel.chooseDirectory.message", kind.displayName)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        showNewSession = false
        newSession(cwd: url.path, kind: kind)
    }

    /// 在后台读某个会话记录的尾部（≤256KB），抽取紧凑的上下文；completion 在主线程（找不到记录时为 nil）。
    func transcriptDigest(for row: SidebarRow, completion: @escaping (AssistantDigest?) -> Void) {
        guard let sid = row.session.sessionID, row.session.kind.isAgent else { return completion(nil) }
        let kind = row.session.kind
        let title = row.displayName
        let status = row.session.status
        let transcripts = self.transcripts
        let agentIndex = self.agentIndex
        queue.async {
            let url: URL? = kind == .claude
                ? transcripts.path(forSession: sid)
                : agentIndex.locate(kind: kind, sessionID: sid).map { URL(fileURLWithPath: $0) }
            let digest = url.map { TurnDigest.digest(kind: kind, tail: TranscriptReader.readTail($0, bytes: TurnDigest.tailBytes)) }
            DispatchQueue.main.async {
                completion(digest.map { AssistantDigest(title: title, status: status, digest: $0) })
            }
        }
    }

    // MARK: 状态集成

    func refreshIntegrations() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let statuses: [AgentKind: IntegrationStatus] = [.codex: CodexIntegration().status(), .pi: PiIntegration().status()]
            DispatchQueue.main.async { self?.integrationStatus = statuses }
        }
    }

    func installIntegration(_ kind: AgentKind) {
        runIntegration(kind, failureTitle: L("integration.installFailed", kind.displayName)) {
            switch kind {
            case .codex: try CodexIntegration().install()
            case .pi: try PiIntegration().install()
            case .claude, .other: break
            }
        }
    }

    func uninstallIntegration(_ kind: AgentKind) {
        guard confirm(L("confirm.uninstallIntegration.title", kind.displayName),
                      L("confirm.uninstallIntegration.message", kind.displayName)) else { return }
        runIntegration(kind, failureTitle: L("integration.uninstallFailed", kind.displayName)) {
            switch kind {
            case .codex: try CodexIntegration().uninstall()
            case .pi: try PiIntegration().uninstall()
            case .claude, .other: break
            }
        }
    }

    private func runIntegration(_ kind: AgentKind, failureTitle: String, _ work: @escaping () throws -> Void) {
        guard !integrationBusy.contains(kind) else { return }
        integrationBusy.insert(kind)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            do { try work() } catch { failure = (error as? IntegrationError)?.message ?? error.localizedDescription }
            DispatchQueue.main.async {
                guard let self else { return }
                self.integrationBusy.remove(kind)
                self.refreshIntegrations()
                if let failure { self.alert(failureTitle, failure) }
            }
        }
    }

    // MARK: 退出与恢复

    /// 返回 true 表示可以退出。
    func confirmQuit() -> Bool {
        let active = sessions.filter { $0.host.isEmbedded && $0.status.isActive }
        if !active.isEmpty {
            let names = active.map { $0.name.isEmpty ? $0.cwd : $0.name }.joined(separator: L("list.separator"))
            guard confirm(LN("confirm.quit.title", active.count), L("confirm.quit.message", names)) else {
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
            // 只记下确实在运行（或有会话可恢复）的 agent；启动失败 / 已退出的不在下次启动时重开。
            let kind = sessionID != nil || observedAgent.contains(terminal.id) ? knownKinds[terminal.id] : nil
            return WorkspaceEntry(terminalID: terminal.id, cwd: cwd, sessionID: sessionID,
                                  name: terminal.title, kind: kind)
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
                // 有 sessionId：按其 agent 恢复（旧文件没有 kind 时为 Claude）；只有 kind 没有 sessionId
                //（如 Codex 还没发过第一条消息）：重新启动该 agent；都没有：普通 shell。
                let kind = entry.kind.flatMap { $0.isAgent ? $0 : nil } ?? (entry.sessionID != nil ? .claude : nil)
                let adapter = kind.flatMap(AgentAdapters.adapter(for:))
                let command = entry.sessionID.map { sid in adapter?.resumeCommand(sessionID: sid) } ?? adapter?.launchCommand()
                makeTerminal(id: entry.terminalID, cwd: entry.cwd, command: command)
                if let kind { remember(entry.terminalID, sessionID: entry.sessionID, kind: kind) }
            } else {
                missing.append(entry)
            }
        }
        if let first = pool.terminals.first { selectedID = "term:\(first.id.uuidString)" }
    }

    // MARK: 内部

    /// 记下某个内嵌终端里预期运行的 agent 会话（恢复 / 接管 / 新建时）。
    private func remember(_ tid: UUID, sessionID: String?, kind: AgentKind) {
        knownKinds[tid] = kind
        knownSessionIDs[tid] = sessionID
    }

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
        knownKinds[tid] = nil
        observedAgent.remove(tid)
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
        alert.addButton(withTitle: L("action.confirm"))
        alert.addButton(withTitle: L("action.cancel"))
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
        alert.messageText = L("alert.automationDenied.title")
        alert.informativeText = L("alert.automationDenied.message")
        alert.addButton(withTitle: L("action.openSystemSettings"))
        alert.addButton(withTitle: L("action.ok"))
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
