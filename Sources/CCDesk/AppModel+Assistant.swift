import Foundation
import CCDeskCore

/// 语音助手对 App 的操作：复用侧栏的现有动作（选中 / 关闭 / 读记录）。会话的短 id 由工具执行器统一分配。
extension AppModel: AssistantHost {
    func sidebarRow(_ rowID: String) -> SidebarRow? {
        groups.lazy.flatMap(\.rows).first { $0.id == rowID }
    }

    /// 侧栏会话（带稳定短 id），按侧栏顺序。
    func assistantSessions() -> [AssistantSessionInfo] {
        groups.flatMap { group in
            group.rows.map { row in
                AssistantSessionInfo(rowID: row.id, shortID: toolbox.shortID(forRow: row.id), title: row.displayName,
                                     dir: group.title, agent: row.session.kind, status: row.session.status,
                                     isSelected: row.id == selectedID, isEmbedded: row.session.host.isEmbedded)
            }
        }
    }

    /// 可新建会话的项目：侧栏分组根目录 + 最近目录。
    func assistantProjects() -> [AssistantProject] {
        var seen = Set<String>()
        return (groups.map { AssistantProject(name: $0.title, path: $0.id) }
            + recentDirs.map { AssistantProject(name: HistoryEntry.projectTitle(root: $0), path: $0) })
            .filter { seen.insert($0.path).inserted }
    }

    func assistantContext(pendingText: String, lastSummary: String?) -> AssistantContext {
        AssistantContext(sessions: assistantSessions(), projects: assistantProjects(), pendingText: pendingText,
                         lastTurnSummary: lastSummary, language: Localization.currentLanguage)
    }

    func assistantRow(_ rowID: String) -> (title: String, status: AgentStatus, isEmbedded: Bool)? {
        sidebarRow(rowID).map { ($0.displayName, $0.session.status, $0.session.host.isEmbedded) }
    }

    func assistantSwitch(to rowID: String) {
        if let row = sidebarRow(rowID) { activate(row) }
    }

    func assistantClose(_ rowID: String) {
        if let row = sidebarRow(rowID) { closeWithoutConfirmation(row) }
    }

    func assistantDigest(rowID: String?, turns: Int, completion: @escaping (AssistantDigest?) -> Void) {
        guard let row = rowID.flatMap(sidebarRow) ?? selectedRow else { return completion(nil) }
        transcriptDigest(for: row, turns: turns, completion: completion)
    }
}
