import AppKit
import CCDeskCore

/// 退出与恢复：workspace 的保存 / 恢复、内嵌终端的创建与移除、最近目录。
extension AppModel {
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
        try? WorkspaceStore.save(WorkspaceFile(entries: embedded + missing, layout: panes.layout))
    }

    func restore() {
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
        restoreLayout(restore.layout)
        // 选回分屏的焦点窗格（没有分屏记录时为上次选中的终端）；它没能恢复时选第一个。
        let last = panes.layout.focused
            ?? UserDefaults.standard.string(forKey: Self.lastSelectedTerminalKey).flatMap(UUID.init(uuidString:))
        if let terminal = pool.terminals.first(where: { $0.id == last }) ?? pool.terminals.first {
            selectedID = "term:\(terminal.id.uuidString)"
        }
    }

    static let lastSelectedTerminalKey = "lastSelectedTerminal"

    /// 记下某个内嵌终端里预期运行的 agent 会话（恢复 / 接管 / 新建时）。
    func remember(_ tid: UUID, sessionID: String?, kind: AgentKind) {
        knownKinds[tid] = kind
        knownSessionIDs[tid] = sessionID
    }

    @discardableResult
    func makeTerminal(id: UUID, cwd: String, command: String?) -> EmbeddedTerminal {
        makeTerminal(id: id, cwd: cwd, launch: .run(command: command))
    }

    @discardableResult
    func makeTerminal(id: UUID, cwd: String, launch: TerminalLaunch) -> EmbeddedTerminal {
        let title = URL(fileURLWithPath: cwd).lastPathComponent
        let terminal = pool.create(id: id, cwd: cwd, title: title, launch: launch)
        terminal.onTerminated = { [weak self] tid in self?.removeTerminal(tid) }
        terminal.onServerLost = { [weak self] tid in self?.tmuxServerLost(tid) }
        terminal.view.onMouseDown = { [weak self] in self?.focusPane(id) }
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

    func removeTerminal(_ tid: UUID) {
        inputs.closed(terminalID: tid)
        pool.remove(tid)
        knownSessionIDs[tid] = nil
        knownKinds[tid] = nil
        observedAgent.remove(tid)
        endedSessionIDs[tid] = nil
        resumingEnded[tid] = nil
        layoutTerminalRemoved(tid)
        saveWorkspace()
        poll()
    }

    func rememberRecent(_ rawCwd: String) {
        let cwd = ProjectResolver.canonical(rawCwd)
        recentDirs = [cwd] + recentDirs.filter { $0 != cwd }.prefix(9)
        UserDefaults.standard.set(recentDirs, forKey: "recentDirs")
    }
}
