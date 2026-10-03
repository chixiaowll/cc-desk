import Foundation
import CCDeskCore

/// 语音助手对 App 的操作：复用侧栏的现有动作（选中 / 新建 / 恢复 / 关闭）。
extension AppModel: AssistantHost {
    private func row(_ rowID: String) -> SidebarRow? {
        groups.lazy.flatMap(\.rows).first { $0.id == rowID }
    }

    func assistantContext(pendingText: String, lastSummary: String?) -> AssistantContext {
        var sessions: [AssistantSessionInfo] = []
        for group in groups {
            for row in group.rows {
                sessions.append(AssistantSessionInfo(rowID: row.id, title: row.displayName, dir: group.title,
                                                     agent: row.session.kind, status: row.session.status,
                                                     isSelected: row.id == selectedID))
            }
        }
        let projects = groups.map { AssistantProject(name: $0.title, path: $0.id) }
            + recentDirs.map { AssistantProject(name: HistoryEntry.projectTitle(root: $0), path: $0) }
        let past = history.prefix(AssistantContext.maxHistory).map {
            AssistantHistoryInfo(sessionID: $0.item.sessionID, title: $0.item.title, dir: $0.projectTitle, agent: $0.item.kind)
        }
        return AssistantContext(sessions: sessions, projects: projects, history: Array(past), pendingText: pendingText,
                                lastTurnSummary: lastSummary, language: Localization.currentLanguage)
    }

    func assistantRow(_ rowID: String) -> (title: String, status: AgentStatus, isEmbedded: Bool)? {
        row(rowID).map { ($0.displayName, $0.session.status, $0.session.host.isEmbedded) }
    }

    func assistantSwitch(to rowID: String) {
        if let row = row(rowID) { activate(row) }
    }

    func assistantNew(dir: String, agent: AgentKind) {
        newSession(cwd: dir, kind: agent)
    }

    func assistantResume(sessionID: String) -> String? {
        guard let entry = history.first(where: { $0.item.sessionID == sessionID }) else { return nil }
        resumeHistory(entry.item)
        return entry.item.title
    }

    func assistantClose(_ rowID: String) {
        if let row = row(rowID) { closeWithoutConfirmation(row) }
    }

    func assistantDigest(rowID: String?, completion: @escaping (AssistantDigest?) -> Void) {
        guard let row = rowID.flatMap(row) ?? selectedRow else { return completion(nil) }
        transcriptDigest(for: row, completion: completion)
    }
}
