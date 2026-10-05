import AppKit
import CCDeskCore

/// 会话动作：选中 / 跳转、新建、恢复、关闭、结束外部进程、接管、历史恢复。
extension AppModel {
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

    /// ⌘1–9：按侧栏从上到下的顺序（与按住 ⌘ 时侧栏上显示的编号一致）。
    func selectNumbered(index: Int) {
        let rows = numberedRows
        guard rows.indices.contains(index) else { return NSSound.beep() }
        let row = rows[index]
        // 在收起的组里：先展开，让选中的那一行看得见。
        if let group = groups.first(where: { $0.rows.contains { $0.id == row.id } }), collapsed.contains(group.id) {
            collapsed.remove(group.id)
        }
        activate(row)
    }

    /// 按住 ⌘ 时在侧栏显示编号：监听修饰键变化，App 失去焦点时复位。
    func startCommandHintMonitor() {
        guard commandMonitor == nil else { return }
        // 按住 ⌘ 约 0.4 秒才显示，免得 ⌘C / ⌘V 这类快捷键一按就闪一下编号；中途按了别的键（⌘ 组合键）也不显示。
        commandMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                self.commandHintToken += 1
                if self.commandHeld { self.commandHeld = false }
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            self.commandHintToken += 1
            if flags == .command {
                let token = self.commandHintToken
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, self.commandHintToken == token else { return }
                    self.commandHeld = true
                }
            } else if self.commandHeld {
                self.commandHeld = false
            }
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            if self?.commandHeld == true { self?.commandHeld = false }
        }
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
        if select {
            placeNewTerminal(terminal.id)
            selectedID = "term:\(terminal.id.uuidString)"
        }
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

    /// 不再确认、直接关闭内嵌会话（语音已确认过）。关闭的是选中的会话时先选中另一个内嵌会话，对话模式得以继续
    /// （分屏时由接替的窗格成为选中，见 `layoutTerminalRemoved`）。
    func closeWithoutConfirmation(_ row: SidebarRow) {
        guard case .embedded(let tid) = row.session.host, let terminal = pool.terminal(tid) else { return }
        if selectedID == row.id, !(panes.layout.isSplit && panes.layout.contains(tid)), let next = embeddedRowsInOrder.first(where: { $0.id != row.id }) {
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
}
