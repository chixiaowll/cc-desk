import AppKit
import Combine
import CCDeskCore

/// 状态中心。只在主线程访问；后台队列只做文件读取和子进程调用。
final class AppModel: ObservableObject {
    @Published var groups: [SessionGroup] = []
    /// 每秒走一次的时钟（侧栏的相对时间）。单独的对象：只有观察它的视图每秒重绘，详情区 / 工具栏不跟着重绘。
    let clock = AppClock()
    /// 最近一次轮询的时刻。
    var now: Date { clock.now }
    /// 每个会话当前这次等批准的编号与开始时刻（通知按钮 / 语音批准核对仍是同一次等待）。
    var waitingEpisodes = WaitingEpisodes(base: Int(Date().timeIntervalSince1970) * 1000)
    @Published var selectedID: String? {
        didSet {
            if let id = selectedID { clearUnread(id) }
            // 记住选中的内嵌终端，下次启动恢复时选回它。
            if let terminalID = selectedTerminalID {
                UserDefaults.standard.set(terminalID.uuidString, forKey: Self.lastSelectedTerminalKey)
            }
            // 对话模式只作用于选中的内嵌 session；没有选中内嵌 session 时自动关闭。
            if selectedTerminalID == nil { conversation.turnOff() }
            layoutFollowSelection()
        }
    }
    @Published var showNewSession = false
    /// 由 ContentView 在 onAppear 时注入，用于在窗口已关闭时重新打开（App 设计上关闭窗口不退出）。
    var openMainWindow: (() -> Void)?
    /// 用户主动打开主窗口（由 AppDelegate 注入 showMainWindow：结束登录启动时的收起、激活并显示）。
    var revealMainWindow: (() -> Void)?
    @Published var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedGroups") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsedGroups") }
    }
    /// 新建会话默认使用的 agent（上次使用的）；只会记住可启动的种类。
    @Published var lastAgent: AgentKind = {
        let stored = UserDefaults.standard.string(forKey: "lastAgent").flatMap(AgentKind.init(rawValue:))
        return stored.flatMap { AgentAdapters.adapter(for: $0) != nil ? $0 : nil } ?? .claude
    }()
    /// 本机检测到的 codex / pi；nil 表示尚未检测完成。
    @Published var installedAgents: Set<AgentKind>?
    var probingAgents = false
    var agentsProbedAt: Date?
    @Published var recentDirs: [String] = UserDefaults.standard.stringArray(forKey: "recentDirs") ?? []
    /// 历史会话（不含当前运行中的），按时间倒序；后台每 30 秒刷新，打开历史弹出层 / 搜索面板时立即刷新。
    @Published var historyEntries: [HistoryEntry] = []
    @Published var showHistoryPalette = false {
        didSet { if showHistoryPalette && !oldValue { refreshHistory() } }
    }
    /// 外部会话行 id -> 宿主 App 的 .app 路径（由进程链推出），用于显示真实 App 图标。
    var hostAppPaths: [String: String] = [:]
    let pool = TerminalPool()
    /// 详情区的分屏布局（设计 §20）。
    let panes = PaneLayoutModel()
    /// 分离到独立窗口的终端（设计 §20.3）。
    private(set) lazy var detachedWindows: DetachedWindows = {
        let windows = DetachedWindows()
        windows.model = self
        return windows
    }()
    let notifier = Notifier()
    /// 推送到手机（设置 › 通知），与系统通知在同一处触发。
    let push = PhonePushCenter()
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
    /// 技能库（设计 §21）。
    private(set) lazy var skills = SkillLibrary(model: self)
    var controlServer: ControlServer?
    let resolver = ProjectResolver(git: SystemProbe.git)
    let queue = DispatchQueue(label: "cc-desk.poll")
    /// 只在 `queue` 上使用（非线程安全）。
    let transcripts = TranscriptIndex()
    /// Codex / pi 会话文件索引；只在 `queue` 上使用。
    let agentIndex = AgentSessionIndex()
    /// pid -> (启动时间, cwd) 缓存；只在 `queue` 上使用。
    var processDetails: [Int32: ProcessDetails] = [:]
    /// Claude 套餐与用量（来自 Claude Code 写在 ~/.claude.json 的缓存，只读）；nil 时不显示。
    @Published var claudeUsage: ClaudeUsage?
    /// 只在 `queue` 上使用；文件 mtime 未变时不重新解析。
    let usageSource = ClaudeUsageSource()
    var refreshingUsage = false
    let usageRefresher = UsageRefresher()
    var sidebarOrder = SidebarOrder.load() ?? SidebarOrder()
    /// Codex / pi 状态集成的安装状态；nil 键表示尚未检测。
    @Published var integrationStatus: [AgentKind: IntegrationStatus] = [:]
    /// 正在安装 / 卸载的集成。
    @Published var integrationBusy: Set<AgentKind> = []
    var refreshingHistory = false
    /// 侧栏上已有对应行的 Claude sessionId（运行中的 + 内嵌终端里已结束、可原地恢复的）；
    /// 历史列表排除这些，并据此在主线程上再过滤一次（后台结果可能已过时）。
    var liveSessionIDs: Set<String> = []
    var timer: Timer?
    /// 正在为重启交接（不再写 workspace、不再启动控制接口）。
    var relaunchSuspended = false
    var polling = false
    var sessions: [AgentSession] = []
    var lastStatuses: [String: AgentStatus]?
    var missing: [WorkspaceEntry] = []
    /// 每个内嵌终端最近一次对应的 agent sessionId 及其种类，用于持久化恢复。
    var knownSessionIDs: [UUID: String] = [:]
    var knownKinds: [UUID: AgentKind] = [:]
    /// 正在接管中的外部进程 pid，防止同一进程被重复接管。
    var takingOver: Set<Int32> = []
    /// 曾经在某个内嵌终端里观测到过 agent 会话的终端 id；用于区分"agent 已退出留下普通 shell"
    /// 与"刚恢复、agent 还没来得及注册"两种情况。
    var observedAgent: Set<UUID> = []
    /// 内嵌终端里 agent 已退出、终端仍留着 shell 时，最近一次的 sessionId、种类与退出时间；侧栏显示为「已结束」并可原地恢复。
    var endedSessionIDs: [UUID: EndedSession] = [:]
    /// 最近一次拿到的 transcript 标题，供刚结束的会话在后台尚未补齐标题时沿用。
    var titleCache: [String: TranscriptMeta] = [:]
    /// 已发出原地恢复命令、claude 尚未注册的终端 -> 发出时间；期间隐藏恢复按钮，防止重复发送。
    @Published var resumingEnded: [UUID: Date] = [:]
    /// 最近一次 poll 的进程表，供「激活 .other 宿主」时查找宿主 App。
    var lastProcesses: ProcessTable?
    var tick = 0
    /// 「测试通知与角标」期间暂时显示示例角标，到期后恢复真实计数。
    var badgePreviewUntil: Date?
    /// 「已完成·未读」的行 id：Claude 完成一轮（working → idle）时用户没在看它。仅内存中保存。
    var unreadKeys: Set<String> = []
    /// 最近一次 poll 的项目解析结果，供未读状态变化时立即重建侧栏。
    var lastProjects: [String: ProjectRef] = [:]

    /// 语音输入（按住右 ⌥ / 麦克风按钮，本机 Whisper 识别后插入选中的内嵌终端）。
    private(set) lazy var voice = VoiceInput(
        pool: pool,
        selectedTerminalID: { [weak self] in self?.selectedTerminalID },
        canListen: { [weak self] in self?.canListenForVoice ?? false })

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
        installTerminalPathClicks()
        notifier.onOpen = { [weak self] key in self?.openFromNotification(key) }
        notifier.onApproval = { [weak self] key, reason, episode, approve in
            self?.respondFromNotification(key, expectedReason: reason, expectedEpisode: episode, approve: approve)
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
        return !showNewSession && !showHistoryPalette && panes.picker == nil && !conversation.isOn
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

    var embeddedRowsInOrder: [SidebarRow] {
        let rows = groups.flatMap(\.rows)
        return pool.terminals.compactMap { t in rows.first { $0.session.host == .embedded(terminalID: t.id) } }
    }
}

/// 每秒走一次的时钟（AppModel 每次轮询时更新）。
final class AppClock: ObservableObject {
    @Published var now = Date()
}
