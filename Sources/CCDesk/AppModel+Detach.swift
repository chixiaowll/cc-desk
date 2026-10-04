import AppKit
import CCDeskCore

/// 独立窗口（设计 §20.3）：把会话从主窗口的布局里拿出来，放进自己的窗口；关闭窗口时放回主窗口，会话不结束。
/// 独立窗口是 key 时选中就是它的终端，语音输入 / 对话模式 / 助手的默认目标随之指向它。
extension AppModel {
    func isDetached(_ tid: UUID) -> Bool { detachedWindows.contains(tid) }

    /// 「在新窗口中打开」：从布局里移走并打开独立窗口（已打开时拿到最前）。
    func detach(_ tid: UUID) {
        guard pool.terminal(tid) != nil else { return }
        if detachedWindows.contains(tid) { return detachedWindows.bringToFront(tid) }
        var layout = panes.layout
        layout.remove(tid)
        commitLayout(layout, save: false)
        // 先记下分离（主窗口的容器随之交出视图），再让窗口成为 key（选中随之指向它）。
        detachedWindows.open(tid)
        saveWorkspace()
    }

    /// 菜单「在新窗口中打开」：焦点窗格的会话。
    func detachFocused() {
        guard let tid = panes.layout.focused else { return NSSound.beep() }
        detach(tid)
    }

    /// 独立窗口成为 key：选中它的终端。
    func selectDetached(_ tid: UUID) {
        guard detachedWindows.contains(tid) else { return }
        selectTerminal(tid)
        // 键盘焦点交给终端（窗口里没有别的可输入控件）。
        if let window = detachedWindows.windowFor(tid), let view = pool.terminal(tid)?.view,
           view.window === window, window.firstResponder !== view {
            window.makeFirstResponder(view)
        }
    }

    /// 主窗口重新成为 key：选中回到主窗口的焦点窗格（主窗口没有窗格时保持原来的选中）。
    func selectFocusedPane() {
        guard let focused = panes.layout.focused else { return }
        selectTerminal(focused)
    }

    /// 标题条的「放回主窗口」：关闭独立窗口（由关闭回调放回布局）。
    func reattachDetached(_ tid: UUID) {
        detachedWindows.close(tid, reattach: true)
    }

    /// 独立窗口被关闭（红色按钮、⌘W、放回主窗口）：放回主窗口——布局为空时成为唯一窗格，焦点窗格右侧放得下时
    /// 分屏放在右侧，否则替换焦点窗格；并选中它。
    func detachedWindowClosed(_ tid: UUID) {
        guard pool.terminal(tid) != nil else { return saveWorkspace() }
        var layout = panes.layout
        if let focused = layout.focused, focused != tid, panes.canSplit(focused, edge: .right) {
            layout.split(focused, edge: .right, with: tid)
        } else {
            layout.show(tid)
        }
        commitLayout(layout)
        selectTerminal(tid)
    }

    /// 要把分离的终端直接放到主窗口某处（拖到窗格上、右键「在右侧分屏打开」）：先关掉它的窗口，不自动放回。
    func undockIfDetached(_ tid: UUID) {
        guard detachedWindows.contains(tid) else { return }
        detachedWindows.close(tid, reattach: false)
    }

    /// 终端被移除：关掉它的独立窗口（不放回）。
    func detachedTerminalRemoved(_ tid: UUID) {
        detachedWindows.close(tid, reattach: false)
        detachedWindows.setPending(detachedWindows.pending.filter { $0.terminalID != tid })
    }

    /// 启动恢复：记下上次分离的终端（没能恢复的忽略），从布局里去掉它们；窗口等 `openPendingDetachedWindows` 再打开。
    func restoreDetached(_ saved: [DetachedWindowEntry]?) {
        let entries = (saved ?? []).filter { pool.terminal($0.terminalID) != nil }
        guard !entries.isEmpty else { return }
        detachedWindows.setPending(entries)
        var layout = panes.layout
        for entry in entries { layout.remove(entry.terminalID) }
        panes.layout = layout
    }

    /// 打开启动时恢复的独立窗口（普通启动时立即；登录启动时等用户第一次打开主窗口）。
    func openPendingDetachedWindows() {
        guard !detachedWindows.pending.isEmpty else { return }
        detachedWindows.openPending()
        objectWillChange.send()
    }
}
