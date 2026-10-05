import AppKit
import CCDeskCore

/// 系统通知的点击与「批准 / 拒绝」按钮。
extension AppModel {
    func openFromNotification(_ key: String) {
        if let revealMainWindow {
            revealMainWindow()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            openMainWindow?()
        }
        if key == CompanionWork.notificationKey {
            work.resultsTab = .companion
            work.showResults = true
            return
        }
        if let row = groups.lazy.flatMap(\.rows).first(where: { $0.id == key }) { activate(row) }
    }

    /// 通知上的「批准 / 拒绝」按钮：不激活 App、不切换选中行，只对通知所属会话的终端发键。
    /// 点击时复核：会话仍在、是内嵌终端、仍在等批准且等待原因与通知时一致，否则不发键并发一条简短提示。
    func respondFromNotification(_ key: String, expectedReason: String?, expectedEpisode: Int?, approve: Bool) {
        let row = groups.lazy.flatMap(\.rows).first { $0.id == key }
        var decision = ApprovalNotification.decide(expectedReason: expectedReason, expectedEpisode: expectedEpisode,
                                                   host: row?.session.host, status: row?.session.status,
                                                   currentEpisode: waitingEpisodes.episode(key)?.id)
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
}
