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
            // 记住选中的内嵌终端，下次启动恢复时选回它。
            if let terminalID = selectedTerminalID {
                UserDefaults.standard.set(terminalID.uuidString, forKey: Self.lastSelectedTerminalKey)
            }
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
    /// 推送到手机（设置 › 通知），与系统通知在同一处触发。
    let push = PhonePushCenter()
    /// 语音输入（按住右 ⌥ / 麦克风按钮，本机 Whisper 识别后插入选中的内嵌终端）。
    private(set) lazy var voice = VoiceInput(
        pool: pool,
        selectedTerminalID: { [weak self] in self?.selectedTerminalID },
        canListen: { [weak self] in self?.canListenForVoice ?? false })
    /// 对话模式（免按键：唤醒词 + 持续监听，语音指令发送 / 清空 / 批准）。开启时忽略按住说话。
    private(set) lazy var conversation = ConversationMode(
        pool: pool, voice: voice, inputs: inputs,
        selectedTerminalID: { [weak self] in self?.selectedTerminalID },
        statusOf: { [weak self] tid in self?.status(ofTerminal: tid) })
    /// 往内嵌终端输入的未发送文字与撤销记录（对话模式与助手工具共用）。
    let inputs = AssistantInputs()
    /// 助手工具的执行者（控制接口 `~/.cc-desk/control.sock` 的方法，设计 §13）。
    private(set) lazy var toolbox = AssistantToolbox(model: self)
    /// 顾问、派活、专业 agent 与主动提醒（设计 §14）。
    private(set) lazy var work = AssistantWork(model: self)
    /// 「改动的文件」面板（设计 §17）。
    private(set) lazy var touchedFiles = TouchedFilesModel(model: self)
    private var controlServer: ControlServer?
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
    private let usageRefresher = UsageRefresher()
    private var sidebarOrder = SidebarOrder.load() ?? SidebarOrder()
    /// Codex / pi 状态集成的安装状态；nil 键表示尚未检测。
    @Published private(set) var integrationStatus: [AgentKind: IntegrationStatus] = [:]
    /// 正在安装 / 卸载的集成。
    @Published private(set) var integrationBusy: Set<AgentKind> = []
    private var refreshingHistory = false
    /// 侧栏上已有对应行的 Claude sessionId（运行中的 + 内嵌终端里已结束、可原地恢复的）；
    /// 历史列表排除这些，并据此在主线程上再过滤一次（后台结果可能已过时）。
    private var liveSessionIDs: Set<String> = []
    private var timer: Timer?
    /// 正在为重启交接（不再写 workspace、不再启动控制接口）。
    private var relaunchSuspended = false
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
            if alert.runModal() == .alertFirstButtonReturn, let url = Notifier.systemSettingsURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: 生命周期

    func start() {
        conversation.host = self
        work.start()
        startControlServer()
        notifier.onOpen = { [weak self] key in self?.openFromNotification(key) }
        notifier.onApproval = { [weak self] key, reason, approve in
            self?.respondFromNotification(key, expectedReason: reason, approve: approve)
        }
        notifier.setup()
        pool.tmux = TmuxHost.shared
        restore()
        if pool.tmux == nil { TerminalRestore.showUnavailableHintOnce() }
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
                expected[terminal.ttyPID] = (kind, sid)
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
    /// 打开用量详情时：缓存超过 20 秒就让 Claude Code 立即重新拉取（定时 5 分钟、任务完成 30 秒见 UsageRefresher）。
    func refreshUsageNow() {
        usageRefresher.refresh(fetchedAt: claudeUsage?.fetchedAt, reason: .opened) { [weak self] in self?.refreshUsage() }
    }

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
        let notifiable = events.filter { !(appVisible && $0.sessionKey == selectedID) }
        for event in notifiable {
            if NotificationPreferences.allows(event.kind) { notifier.post(event) }
            if event.kind == .finished, unreadKeys.insert(event.sessionKey).inserted { newlyUnread = true }
        }
        push.handle(notifiable, rows: rows)
        if newlyUnread { rebuildGroups() }
        work.observe(events: events, rows: rows)
        if events.contains(where: { $0.kind == .finished }) {
            usageRefresher.refresh(fetchedAt: claudeUsage?.fetchedAt, reason: .taskFinished) { [weak self] in self?.refreshUsage() }
        }
        updateBadge()
        conversation.observe(terminalID: selectedTerminalID,
                             status: selectedTerminalID.flatMap { status(ofTerminal: $0) })

        tick += 1
        if tick % 600 == 1 { queue.async { HookStateReader.prune() } }
        if tick % 30 == 0 {
            saveWorkspace()
            refreshHistory()
            refreshUsage()
            usageRefresher.refresh(fetchedAt: claudeUsage?.fetchedAt, reason: .periodic) { [weak self] in self?.refreshUsage() }
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
        let built = SidebarBuilder.build(
            sessions: sessions,
            project: { projects[$0] ?? ProjectRef(root: $0, branch: nil, cwd: $0) },
            titles: { [titleCache] s in s.sessionID.flatMap { titleCache[$0] } },
            unread: { unread.contains($0.id) })
        // 固定顺序：按第一次出现的先后排列，重启后保持，状态变化不再改变位置。
        let ordered = sidebarOrder.apply(built)
        groups = ordered.groups
        if ordered.changed {
            let snapshot = sidebarOrder
            queue.async { snapshot.save() }
        }
    }

    // MARK: 侧栏顺序（右键菜单 / 拖拽）

    func moveGroup(_ id: String, _ move: SidebarOrder.Move) {
        sidebarOrder.moveGroup(id, move, in: groups.map(\.id))
        orderChanged()
    }

    func moveRow(_ row: SidebarRow, _ move: SidebarOrder.Move) {
        guard let group = groups.first(where: { $0.rows.contains { $0.id == row.id } }) else { return }
        sidebarOrder.moveRow(row.id, move, in: group.rows)
        orderChanged()
    }

    /// 拖拽：payload 为 "group:<id>" 或 "row:<id>"；放到同类的目标上即占据目标的位置（会话只能在组内移动）。
    func dropForReorder(_ payload: String, ontoGroup groupID: String?, ontoRow rowID: String?) -> Bool {
        if payload.hasPrefix("group:"), let groupID {
            let id = String(payload.dropFirst("group:".count))
            let ids = groups.map(\.id)
            guard id != groupID, let index = ids.firstIndex(of: groupID) else { return false }
            sidebarOrder.moveGroup(id, to: index, in: ids)
        } else if payload.hasPrefix("row:"), let rowID {
            let id = String(payload.dropFirst("row:".count))
            guard id != rowID, let group = groups.first(where: { $0.rows.contains { $0.id == rowID } }),
                  group.rows.contains(where: { $0.id == id }),
                  let index = group.rows.firstIndex(where: { $0.id == rowID }) else { return false }
            sidebarOrder.moveRow(id, to: index, in: group.rows)
        } else {
            return false
        }
        orderChanged()
        return true
    }

    private func orderChanged() {
        rebuildGroups()
        let snapshot = sidebarOrder
        queue.async { snapshot.save() }
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

    /// 用 `kind`（默认上次使用的 agent）在目录中新建内嵌会话；prompt 作为第一句话（助手工具用）。
    /// command：自定义启动命令（派活带专业 agent 配置时，设计 §14）；select = false 时不切换选中（后台派活）。
    /// 返回新终端的 id；没能新建时 nil。
    @discardableResult
    func newSession(cwd rawCwd: String, kind: AgentKind? = nil, prompt: String? = nil, command: String? = nil,
                    select: Bool = true) -> UUID? {
        let kind = kind ?? lastAgent
        guard let launcher = AgentAdapters.adapter(for: kind) else {
            alert(L("alert.cannotCreate.title"), L("alert.cannotCreate.message"))
            return nil
        }
        let cwd = ProjectResolver.canonical(rawCwd)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            alert(L("alert.directoryMissing.title"), cwd)
            return nil
        }
        if availability(of: kind) == .notInstalled {
            alert(L("alert.agentNotFound.title", kind.displayName), L("alert.agentNotFound.message", launcher.launchCommand()))
            return nil
        }
        if select, lastAgent != kind {
            lastAgent = kind
            UserDefaults.standard.set(kind.rawValue, forKey: "lastAgent")
        }
        let terminal = makeTerminal(id: UUID(), cwd: cwd, command: command ?? launcher.launchCommand(prompt: prompt))
        knownKinds[terminal.id] = kind
        if select { selectedID = "term:\(terminal.id.uuidString)" }
        rememberRecent(cwd)
        saveWorkspace()
        poll()
        return terminal.id
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
        // 确认框可能开着很久：先记下进程身份，发信号前复核，pid 被复用时不误杀别的进程。
        guard let identity = ProcessIdentity.current(pid: pid) else { return processGone() }
        guard confirm(L("confirm.kill.title", row.displayName), L("confirm.kill.message", Int(pid))) else { return }
        guard identity.matches(ProcessIdentity.current(pid: pid)) else { return processGone() }
        kill(pid, SIGTERM)
        poll()
    }

    /// 要结束 / 接管的进程已经不在（或 pid 已换成别的进程）。
    private func processGone() {
        alert(L("alert.processGone.title"), L("alert.processGone.message"))
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
        guard let identity = ProcessIdentity.current(pid: pid) else { return processGone() }
        if !confirmed, row.session.status.isActive,
           !confirm(L("confirm.takeOver.title", row.displayName), L("confirm.takeOver.message", row.session.status.label)) { return }
        let cwd = ProjectResolver.canonical(row.session.cwd)
        guard FileManager.default.fileExists(atPath: cwd) else {
            alert(L("alert.directoryMissing.title"), cwd)
            return
        }
        // 确认之后再核对一次：仍是当初那个进程才发信号。
        guard identity.matches(ProcessIdentity.current(pid: pid)) else { return processGone() }
        takingOver.insert(pid)
        kill(pid, SIGTERM)
        DispatchQueue.global().async { [weak self] in
            var alive = true
            for _ in 0..<50 {
                // 按身份判断：退出后 pid 被复用也算已退出。
                if !identity.matches(ProcessIdentity.current(pid: pid)) { alive = false; break }
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
    /// turns > 0 时只取最近几轮。
    func transcriptDigest(for row: SidebarRow, turns: Int = 0, completion: @escaping (AssistantDigest?) -> Void) {
        guard let sid = row.session.sessionID, row.session.kind.isAgent else { return completion(nil) }
        let kind = row.session.kind
        let title = row.displayName
        let status = row.session.status
        queue.async { [weak self] in
            let url = self?.transcriptURL(kind: kind, sessionID: sid)
            let digest = url.map { url -> String in
                let tail = TranscriptReader.readTail(url, bytes: TurnDigest.tailBytes)
                return turns > 0 ? TurnDigest.digest(kind: kind, tail: tail, turns: turns) : TurnDigest.digest(kind: kind, tail: tail)
            }
            DispatchQueue.main.async {
                completion(digest.map { AssistantDigest(title: title, status: status, digest: $0) })
            }
        }
    }

    /// 会话记录文件：Claude 查 TranscriptIndex，Codex / pi 查 AgentSessionIndex；只在 `queue` 上调用。
    private func transcriptURL(kind: AgentKind, sessionID: String) -> URL? {
        kind == .claude
            ? transcripts.path(forSession: sessionID)
            : agentIndex.locate(kind: kind, sessionID: sessionID).map { URL(fileURLWithPath: $0) }
    }

    /// 在后台定位会话记录文件（找不到时为 nil）；completion 在主线程。
    func locateTranscript(kind: AgentKind, sessionID: String, completion: @escaping (URL?) -> Void) {
        queue.async { [weak self] in
            let url = self?.transcriptURL(kind: kind, sessionID: sessionID)
            DispatchQueue.main.async { completion(url) }
        }
    }

    /// 某个 cwd 所属项目的根目录（最近一次轮询的解析结果；未解析过时为 nil）。
    func projectRoot(forCwd cwd: String) -> String? {
        lastProjects[cwd]?.root
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
        // tmux 托管的会话在退出后继续运行（只是断开），不必确认；只有直连 PTY 的会话会被中断。
        let active = sessions.filter { s in
            guard s.status.isActive, let tid = s.host.terminalID, let terminal = pool.terminal(tid) else { return false }
            return !terminal.isPersistent
        }
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
        guard !relaunchSuspended else { return }
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
        let restore = TerminalRestore.prepare(tmux: pool.tmux)
        for item in restore.plan.items {
            let entry = item.entry
            let kind = TerminalRestorePlanner.kind(for: entry)
            switch item.decision {
            case .attach:
                // 会话还在运行：直接附着，不发恢复命令。记下 agent，若它在 App 关闭期间已退出，首轮即显示为「已结束」。
                guard let pane = restore.panes[entry.terminalID] else { continue }
                makeTerminal(id: entry.terminalID, cwd: entry.cwd, launch: .attach(pane))
                if let kind {
                    remember(entry.terminalID, sessionID: entry.sessionID, kind: kind)
                    if entry.sessionID != nil { observedAgent.insert(entry.terminalID) }
                }
            case .create(let command):
                makeTerminal(id: entry.terminalID, cwd: entry.cwd, command: command)
                if let kind { remember(entry.terminalID, sessionID: entry.sessionID, kind: kind) }
            case .missing:
                missing.append(entry)
            }
        }
        // 收养了没有记录的会话：立即写进 workspace。
        if !restore.plan.adopted.isEmpty { saveWorkspace() }
        // 选回上次选中的终端；它没能恢复时选第一个。
        let last = UserDefaults.standard.string(forKey: Self.lastSelectedTerminalKey).flatMap(UUID.init(uuidString:))
        if let terminal = pool.terminals.first(where: { $0.id == last }) ?? pool.terminals.first {
            selectedID = "term:\(terminal.id.uuidString)"
        }
    }

    static let lastSelectedTerminalKey = "lastSelectedTerminal"

    // MARK: 内部

    /// 记下某个内嵌终端里预期运行的 agent 会话（恢复 / 接管 / 新建时）。
    private func remember(_ tid: UUID, sessionID: String?, kind: AgentKind) {
        knownKinds[tid] = kind
        knownSessionIDs[tid] = sessionID
    }

    @discardableResult
    private func makeTerminal(id: UUID, cwd: String, command: String?) -> EmbeddedTerminal {
        makeTerminal(id: id, cwd: cwd, launch: .run(command: command))
    }

    @discardableResult
    private func makeTerminal(id: UUID, cwd: String, launch: TerminalLaunch) -> EmbeddedTerminal {
        let title = URL(fileURLWithPath: cwd).lastPathComponent
        let terminal = pool.create(id: id, cwd: cwd, title: title, launch: launch)
        terminal.onTerminated = { [weak self] tid in self?.removeTerminal(tid) }
        terminal.onServerLost = { [weak self] tid in self?.tmuxServerLost(tid) }
        return terminal
    }

    /// tmux 服务器崩溃 / 被结束：会话里的 agent 已经没了。有可恢复的会话时，同一位置换上一个新 shell 并显示为
    /// 「已结束」（可原地恢复）；否则照旧移除终端。
    private func tmuxServerLost(_ tid: UUID) {
        guard let old = pool.terminal(tid) else { return }
        guard let sid = knownSessionIDs[tid] else { return removeTerminal(tid) }
        let kind = knownKinds[tid] ?? .claude
        pool.remove(tid)
        knownSessionIDs[tid] = nil
        knownKinds[tid] = nil
        observedAgent.remove(tid)
        makeTerminal(id: tid, cwd: old.cwd, command: nil)
        endedSessionIDs[tid] = EndedSession(id: sid, kind: kind, at: Date())
        TmuxHost.log("tmux: server lost; \(tid.uuidString) kept as ended session \(sid)")
        saveWorkspace()
        poll()
    }

    private func removeTerminal(_ tid: UUID) {
        inputs.closed(terminalID: tid)
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

    /// 启动控制接口。socket 仍被别的进程占着（多半是切换语言重启时还没退出的旧实例）时，每 0.5 秒重试，最多 10 秒。
    private func startControlServer(attempt: Int = 0) {
        guard controlServer == nil, !relaunchSuspended else { return }
        let toolbox = self.toolbox
        let server = ControlServer(path: ControlProtocol.socketPath(), token: ControlAuth.token,
                                   log: { AssistantDiag.log($0) }) { request, reply in
            DispatchQueue.main.async { toolbox.handle(request, reply: reply) }
        }
        if server.start() {
            controlServer = server
        } else if attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startControlServer(attempt: attempt + 1) }
        }
    }

    func stopControlServer() {
        controlServer?.stop()
        controlServer = nil
    }

    /// 切换语言重启前：存好 workspace，停掉轮询（之后不再写 workspace）与控制接口，让新实例接手。
    func suspendForRelaunch() {
        saveWorkspace()
        relaunchSuspended = true
        timer?.invalidate()
        timer = nil
        stopControlServer()
    }

    /// 新实例没能启动：恢复轮询与控制接口。
    func resumeAfterFailedRelaunch() {
        relaunchSuspended = false
        startControlServer()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
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

    /// 通知上的「批准 / 拒绝」按钮：不激活 App、不切换选中行，只对通知所属会话的终端发键。
    /// 点击时复核：会话仍在、是内嵌终端、仍在等批准且等待原因与通知时一致，否则不发键并发一条简短提示。
    private func respondFromNotification(_ key: String, expectedReason: String?, approve: Bool) {
        let row = groups.lazy.flatMap(\.rows).first { $0.id == key }
        var decision = ApprovalNotification.decide(expectedReason: expectedReason, host: row?.session.host,
                                                   status: row?.session.status)
        let terminal = row?.session.host.terminalID.flatMap(pool.terminal)
        if decision == .apply, terminal == nil { decision = .gone }
        let verb = approve ? "approve" : "deny"
        AssistantDiag.log("notification \(verb) \(key) reason=\(expectedReason ?? "-") -> \(decision)")
        let name = row?.notificationName ?? L("notify.approval.unknownSession")
        guard decision == .apply, let terminal else {
            let body: String
            switch decision {
            case .reasonChanged: body = L("notify.approval.changed")
            case .notWaiting: body = L("notify.approval.notWaiting")
            case .gone, .notEmbedded, .apply: body = L("notify.approval.gone")
            }
            notifier.postNotice(title: L("notify.approval.notSent.title", name), body: body, sessionKey: row?.id)
            return
        }
        terminal.respondToPermission(approve: approve)
        clearUnread(key)
        notifier.removeDelivered(sessionKey: key)
        // 立即刷新一次，让侧栏与 Dock 角标尽快去掉这条等批准。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.poll() }
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
