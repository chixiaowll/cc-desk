import AppKit
import CCDeskCore

/// 启动时恢复内嵌终端（设计 §4.9）：读 workspace、列出 CC Desk tmux 服务器里存活的会话、
/// 决定每个终端是附着还是新建并恢复，并清理没有记录的残留会话。
struct TerminalRestore {
    let plan: TerminalRestorePlan
    /// 存活会话的窗格（附着时用来查 tty）。
    let panes: [UUID: TmuxPane]

    static func prepare(tmux: TmuxHost?, workspaceURL: URL = WorkspaceStore.defaultURL) -> TerminalRestore {
        let fileExisted = FileManager.default.fileExists(atPath: workspaceURL.path)
        let file = WorkspaceStore.load(from: workspaceURL)
        let entries = (file?.entries ?? []).map { raw -> WorkspaceEntry in
            var entry = raw
            entry.cwd = ProjectResolver.canonical(entry.cwd)
            return entry
        }
        let started = Date()
        let live = tmux?.livePanes() ?? []
        if !live.isEmpty { tmux?.reloadConfig() }
        let plan = TerminalRestorePlanner.plan(entries: entries, liveSessions: live.map(\.sessionName),
                                               directoryExists: isDirectory)
        if let tmux, !plan.orphanSessions.isEmpty {
            // workspace 文件损坏（已被挪到一边）时不清理：那些会话可能正是用户还在跑的 agent。
            if fileExisted && file == nil {
                TmuxHost.log("tmux: workspace unreadable, keeping \(plan.orphanSessions.count) unrecorded session(s)")
            } else {
                for name in plan.orphanSessions {
                    TmuxHost.log("tmux: killing orphan session \(name)")
                    tmux.killSession(name: name)
                }
            }
        }
        if tmux != nil {
            let attached = plan.items.filter { $0.decision == .attach }.count
            TmuxHost.log(String(format: "tmux: restore found %d live session(s), attaching %d, in %.0f ms",
                                     live.count, attached, Date().timeIntervalSince(started) * 1000))
        }
        return TerminalRestore(plan: plan, panes: TmuxListing.panesByTerminal(live))
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static let hintShownKey = "tmuxUnavailableHintShown"

    /// 没有可用的 tmux 时提示一次（会话不能跨 App 重启保持）。
    static func showUnavailableHintOnce() {
        guard !UserDefaults.standard.bool(forKey: hintShownKey) else { return }
        UserDefaults.standard.set(true, forKey: hintShownKey)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = L("alert.tmuxUnavailable.title")
            alert.informativeText = L("alert.tmuxUnavailable.message")
            alert.runModal()
        }
    }
}
