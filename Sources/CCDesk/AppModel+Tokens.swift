import Foundation
import CCDeskCore

/// token 统计（设计 §27）：在后台增量读会话记录，发布每个运行中会话的累计用量与今天 / 近 7 天的汇总。
extension AppModel {
    /// 有处理中的会话时每 15 秒、否则每 60 秒刷新一次；force（有会话完成一轮 / 打开用量详情）时立即刷新。
    /// 只在主线程调用；同一时间只有一次刷新在跑。
    func refreshTokens(force: Bool = false) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let working = sessions.contains { $0.status == .working }
        let period: TimeInterval = working ? 15 : 60
        guard !tokenRefreshing, force || uptime - tokenLastRefresh >= period else { return }
        tokenRefreshing = true
        tokenLastRefresh = uptime
        let live = sessions.compactMap { s in s.sessionID.map { (kind: s.kind, id: $0) } }.filter { $0.kind.isAgent }
        // 项目名：cwd 所属项目根目录的最后一级（来自最近一次轮询的解析）；没解析过的取 cwd 本身的最后一级。
        let projects = lastProjects
        let ledger = tokenLedger
        tokenQueue.async { [weak self] in
            ledger.refresh()
            var perSession: [String: SessionTokenSummary] = [:]
            for s in live {
                if let summary = ledger.session(kind: s.kind, sessionID: s.id) { perSession[s.id] = summary }
            }
            let name: (String?) -> String = { cwd in
                guard let cwd else { return "?" }
                return ((projects[cwd]?.root ?? cwd) as NSString).lastPathComponent
            }
            let now = Date()
            let overview = TokenOverview(
                today: ledger.summary(since: Calendar.current.startOfDay(for: now), project: name),
                week: ledger.summary(since: now.addingTimeInterval(-TokenLedger.window), project: name))
            DispatchQueue.main.async {
                guard let self else { return }
                self.tokenRefreshing = false
                if self.sessionTokens != perSession { self.sessionTokens = perSession }
                if self.tokenOverview != overview { self.tokenOverview = overview }
            }
        }
    }

    /// 侧栏行的 token 悬停提示（没有记录时为 nil）。
    func tokenTooltip(for row: SidebarRow) -> String? {
        row.session.sessionID.flatMap { sessionTokens[$0] }?.tooltipText
    }
}
