import AppKit
import CCDeskCore

/// 启动时恢复内嵌终端（设计 §4.9）：读 workspace、列出 CC Desk tmux 服务器里存活的会话、
/// 决定每个终端是附着还是新建并恢复。没有记录的存活会话（workspace 缺失 / 损坏 / 被别的实例写掉）作为内嵌终端收养，
/// 从不在启动时结束任何会话——里面多半是用户还在跑的 agent。
struct TerminalRestore {
    let plan: TerminalRestorePlan
    /// 存活会话的窗格（附着时用来查 tty）。
    let panes: [UUID: TmuxPane]
    /// 保存的分屏布局（设计 §20）；旧文件没有。
    var layout: PaneLayout?
    /// 保存的独立窗口（设计 §20.3）。
    var detached: [DetachedWindowEntry]?

    static func prepare(tmux: TmuxHost?, workspaceURL: URL = WorkspaceStore.defaultURL) -> TerminalRestore {
        let file = WorkspaceStore.load(from: workspaceURL)
        let entries = (file?.entries ?? []).map { raw -> WorkspaceEntry in
            var entry = raw
            entry.cwd = ProjectResolver.canonical(entry.cwd)
            return entry
        }
        let started = Date()
        let live = tmux?.livePanes() ?? []
        if !live.isEmpty { tmux?.reloadConfig() }
        let panes = TmuxListing.panesByTerminal(live)
        let plan = TerminalRestorePlanner.plan(
            entries: entries, liveSessions: live.map(\.sessionName), directoryExists: isDirectory,
            cwdOf: { name in
                TmuxNaming.terminalID(fromSessionName: name).flatMap { panes[$0]?.currentPath }.map(ProjectResolver.canonical)
            },
            fallbackCwd: NSHomeDirectory())
        if tmux != nil {
            for id in plan.adopted {
                TmuxHost.log("tmux: adopting unrecorded session \(TmuxNaming.sessionName(for: id))")
            }
            for name in plan.unknownSessions { TmuxHost.log("tmux: leaving unknown session \(name) alone") }
            let attached = plan.items.filter { $0.decision == .attach }.count
            TmuxHost.log(String(format: "tmux: restore found %d live session(s), attaching %d (%d adopted), in %.0f ms",
                                live.count, attached, plan.adopted.count, Date().timeIntervalSince(started) * 1000))
        }
        return TerminalRestore(plan: plan, panes: panes, layout: file?.layout, detached: file?.detached)
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
