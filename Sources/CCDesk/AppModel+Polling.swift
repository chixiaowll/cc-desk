import AppKit
import CCDeskCore

/// 轮询（节奏见 PollPacer：看着时每秒、否则每 4 秒、状态文件变化时立即）：在后台读注册表、进程表、hook 状态与记录标题，回到主线程合并成侧栏；未读、角标、历史与用量的刷新。
extension AppModel {
    func poll() {
        guard !polling else { return }
        polling = true
        pacer.pollStarted()
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
            self.openCodeMirror.sync()
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
            self.openCodeMirror.sync()
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
                if self.claudeUsage != usage {
                    self.claudeUsage = usage
                    self.displayDirty = true
                }
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

    private func apply(registry raw: [RegistryEntry], processes: ProcessTable, agents snapshots: [AgentProcessSnapshot],
                       projects: [String: ProjectRef], titles: [String: TranscriptMeta]) {
        polling = false
        let registry = registryStatus.resolve(raw)
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
        // 新出现的会话：记下 FSEvents 位置，第一次选中时从这里回放项目里生成的文件（只在集合变化时）。
        let addedLive = liveSessionIDs.subtracting(previousLive)
        if !addedLive.isEmpty { touchedFiles.noteNewSessions(addedLive) }
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
        let statuses = Dictionary(rows.map { ($0.id, $0.session.status) }, uniquingKeysWith: { a, _ in a })
        waitingEpisodes.update(statuses: statuses, now: ProcessInfo.processInfo.systemUptime)
        let events = waitingEpisodes.stamp(TransitionDetector.events(previous: lastStatuses, rows: rows))
        lastStatuses = statuses
        // 系统通知 / 未读不发给正看着的会话；推送对它只在用户离开 Mac 时发（EventRouting）。
        var presence: PushPresence?
        let pushAlways = PushSettings.load().condition == .always
        let routes = EventRouting.route(events: events, selected: selectedID, appVisible: appVisible,
                                        pushAlways: pushAlways) {
            let value = presence ?? PresenceProbe.current()
            presence = value
            return value
        }
        for event in routes.notify where NotificationPreferences.allows(event.kind) { notifier.post(event) }
        // 每个状态事件的去向（排查「为什么没收到通知 / 推送」；只记种类与去向，不记标题内容）。
        for event in events {
            let notified = routes.notify.contains(event) && NotificationPreferences.allows(event.kind)
            AssistantDiag.log("event kind=\(event.kind) watched=\(appVisible && event.sessionKey == selectedID) " +
                              "notify=\(notified) push=\(routes.push.contains(event))")
        }
        let newlyUnread = !routes.unread.subtracting(unreadKeys).isEmpty
        unreadKeys.formUnion(routes.unread)
        push.handle(routes.push, rows: rows, presence: presence)
        if newlyUnread { rebuildGroups() }
        work.observe(events: events, rows: rows)
        if events.contains(where: { $0.kind == .finished }) {
            usageRefresher.refresh(fetchedAt: claudeUsage?.fetchedAt, reason: .taskFinished) { [weak self] in self?.refreshUsage() }
        }
        refreshTokens(force: events.contains(where: { $0.kind == .finished }))
        updateBadge()
        conversation.observe(terminalID: selectedTerminalID,
                             status: selectedTerminalID.flatMap { status(ofTerminal: $0) })

        let uptime = ProcessInfo.processInfo.systemUptime
        if periodicPrune.due(now: uptime, fireFirst: true) { queue.async { HookStateReader.prune() } }
        if periodicRefresh.due(now: uptime) {
            saveWorkspace()
            refreshHistory()
            refreshUsage()
            usageRefresher.refresh(fetchedAt: claudeUsage?.fetchedAt, reason: .periodic) { [weak self] in self?.refreshUsage() }
        } else if !previousLive.subtracting(liveSessionIDs).isEmpty {
            // 有会话从侧栏消失（如关闭了已结束的终端）：立即刷新，让它回到历史列表。
            refreshHistory()
        }
        updateDisplayClock()
        pacer.pollFinished()
    }

    /// 侧栏显示时钟：内容变过、或到了某个相对时间 / 用量文字会变的时刻才前进（相同的值不发布），
    /// 否则不动，侧栏不因时钟重绘。精度为轮询间隔（看着时 1 秒，否则 4 秒）。
    func updateDisplayClock() {
        let wall = now
        guard displayDirty || nextDisplayChange.map({ wall >= $0 }) == true else { return }
        displayDirty = false
        if clock.now != wall { clock.now = wall }
        let dates = groups.flatMap { $0.rows.map(\.session.statusChangedAt) }
        nextDisplayChange = DisplayClock.nextChange(dates: dates, usage: claudeUsage, after: wall, calendar: .current)
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
            let merged = AgentResolver.status(hook: snap.hook, screen: screen, startedAt: snap.startedAt, now: now,
                                              lastActivity: snap.lastActivity)
            return AgentProcessInfo(pid: snap.pid, kind: snap.kind, tty: snap.tty, cwd: snap.cwd,
                                    sessionID: snap.sessionID, status: merged.status, statusChangedAt: merged.at)
        }
        for terminal in pool.terminals { terminal.detectionKind = detecting[terminal.id] }
        return infos
    }

    /// 用最近一次 poll 的会话重建侧栏分组（带上当前的未读集合）。
    func rebuildGroups() {
        let projects = lastProjects
        let unread = unreadKeys
        let built = SidebarBuilder.build(
            sessions: sessions,
            project: { projects[$0] ?? ProjectRef(root: $0, branch: nil, cwd: $0) },
            titles: { [titleCache] s in s.sessionID.flatMap { titleCache[$0] } },
            unread: { unread.contains($0.id) })
        // 固定顺序：按第一次出现的先后排列，重启后保持，状态变化不再改变位置。
        let ordered = sidebarOrder.apply(built)
        // 没变时不重新赋值：@Published 每次赋值都会让所有观察 AppModel 的视图重绘。
        if groups != ordered.groups {
            groups = ordered.groups
            displayDirty = true
        }
        if ordered.changed {
            let snapshot = sidebarOrder
            queue.async { snapshot.save() }
        }
    }

    /// 清除某行的未读标记，并立即刷新侧栏与 Dock 角标。
    func clearUnread(_ id: String) {
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
}
