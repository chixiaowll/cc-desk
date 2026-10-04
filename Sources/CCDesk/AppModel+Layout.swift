import AppKit
import CCDeskCore

/// 分屏（设计 §20）：焦点窗格 == 选中的会话。选中变化时布局跟着走（已显示则聚焦，否则替换焦点窗格）；
/// 关窗格只是不再显示，会话仍在侧栏里；会话结束 / 关闭时它的窗格收拢。
extension AppModel {
    /// 某个内嵌终端在侧栏上的行。
    /// 主窗口里聚焦的窗格对应的行：主窗口的标题栏 / 改动的文件面板跟它走，
    /// 而不是全局选中（独立窗口在前时全局选中是独立窗口里的会话）。主窗口没有窗格时退回全局选中。
    var mainWindowRow: SidebarRow? {
        if let focused = panes.layout.focused { return row(forTerminal: focused) }
        return selectedRow
    }

    func row(forTerminal tid: UUID) -> SidebarRow? {
        groups.lazy.flatMap(\.rows).first { $0.session.host == .embedded(terminalID: tid) }
    }

    /// 选中变化时调用（selectedID 的 didSet）：选中的内嵌终端显示在布局里并成为焦点；
    /// 分离到独立窗口的终端不进布局，改为把它的窗口拿到最前（设计 §20.3）。
    func layoutFollowSelection() {
        guard let tid = selectedTerminalID, pool.terminal(tid) != nil else { return }
        if detachedWindows.owns(tid) { return detachedWindows.bringToFront(tid) }
        var layout = panes.layout
        layout.show(tid)
        commitLayout(layout)
    }

    /// 写回布局；变了才发布与保存（save = false 时只发布，如拖动分隔线的过程中）。
    func commitLayout(_ layout: PaneLayout, save: Bool = true) {
        guard layout != panes.layout else { return }
        panes.layout = layout
        if save { saveWorkspace() }
    }

    /// 选中某个终端（焦点跟过去）；nil 时清除选中。
    func selectTerminal(_ tid: UUID?) {
        let id = tid.map { "term:\($0.uuidString)" }
        if selectedID != id { selectedID = id }
    }

    // MARK: 焦点

    /// 点了某个窗格（终端本身、留白或标题条）：选中它。
    func focusPane(_ tid: UUID) {
        guard panes.layout.contains(tid) else { return }
        selectTerminal(tid)
    }

    /// ⌥⌘←/→/↑/↓：把焦点移到相邻的窗格。
    func moveFocus(_ edge: PaneEdge) {
        var layout = panes.layout
        guard let target = layout.moveFocus(edge) else { return NSSound.beep() }
        commitLayout(layout)
        selectTerminal(target)
        focusSelectedTerminal()
    }

    /// ⇧⌘↩ / 窗格标题条的放大按钮：放大或还原（nil 为焦点窗格）。
    func toggleZoom(_ tid: UUID? = nil) {
        var layout = panes.layout
        layout.toggleZoom(tid)
        commitLayout(layout)
        if let focused = layout.focused { selectTerminal(focused) }
        focusSelectedTerminal()
    }

    /// 拖动分隔线（拖动开始时的分隔线 + 位移）：按最小窗格尺寸限制，过程中只发布，松手（save）时保存。
    func resizePane(_ divider: PaneDivider, by delta: CGFloat, save: Bool) {
        let ratio = panes.layout.ratio(dragging: divider, by: delta, in: panes.areaSize, minPane: PaneLayoutModel.minPane)
        setPaneRatio(ratio, at: divider.path, save: save)
    }

    func setPaneRatio(_ ratio: Double, at path: PanePath, save: Bool) {
        var layout = panes.layout
        guard layout.setRatio(ratio, at: path) else { return }
        commitLayout(layout, save: false)
        if save { saveWorkspace() }
    }

    // MARK: 打开到分屏

    /// 会话能否在焦点窗格旁边分屏打开（右键菜单的可用状态）。
    func canOpenInSplit(_ tid: UUID, edge: PaneEdge) -> Bool {
        guard pool.terminal(tid) != nil, let target = panes.layout.focused, target != tid else {
            return panes.layout.isEmpty && pool.terminal(tid) != nil
        }
        // 已在别的窗格里：移过去，不增加窗格数。
        if panes.layout.contains(tid) { return true }
        return panes.canSplit(target, edge: edge)
    }

    /// 在 `target`（默认焦点窗格）的 `edge` 一侧分屏显示已有会话，并选中它。
    func openInSplit(_ tid: UUID, edge: PaneEdge, beside target: UUID? = nil) {
        guard pool.terminal(tid) != nil else { return }
        undockIfDetached(tid)
        var layout = panes.layout
        guard let target = target ?? layout.focused else {
            layout.show(tid)
            commitLayout(layout)
            return selectTerminal(tid)
        }
        guard target != tid else { return selectTerminal(tid) }
        guard layout.contains(tid) || panes.canSplit(target, edge: edge),
              layout.split(target, edge: edge, with: tid) else { return NSSound.beep() }
        commitLayout(layout)
        selectTerminal(tid)
    }

    /// ⌘D / ⇧⌘D：在焦点窗格旁边分屏，弹出面板选择放什么（已有会话或新建）。
    func requestSplit(_ edge: PaneEdge) {
        guard let target = panes.layout.focused, pool.terminal(target) != nil else { return NSSound.beep() }
        guard panes.canSplit(target, edge: edge) else { return NSSound.beep() }
        showHistoryPalette = false
        panes.picker = PaneSplitRequest(target: target, edge: edge)
    }

    /// 分屏面板里能选的会话：侧栏顺序里还没显示在窗格里的内嵌会话。
    var splitCandidates: [SidebarRow] {
        embeddedRowsInOrder.filter { row in
            row.session.host.terminalID.map { !panes.layout.contains($0) && !detachedWindows.owns($0) } ?? false
        }
    }

    /// 分屏面板选了一个已有会话。
    func completeSplit(_ request: PaneSplitRequest, with tid: UUID) {
        panes.picker = nil
        openInSplit(tid, edge: request.edge, beside: request.target)
        focusSelectedTerminal()
    }

    /// 分屏面板选了「新建会话…」：打开新建表单，建好的会话放进这个分屏。
    func completeSplitWithNewSession(_ request: PaneSplitRequest) {
        panes.picker = nil
        panes.pendingSplit = request
        showNewSession = true
    }

    func cancelSplitPicker() {
        panes.picker = nil
        focusSelectedTerminal()
    }

    /// 新建会话即将被选中：有待放置的分屏时放到那里（否则选中时替换焦点窗格）。
    func placeNewTerminal(_ tid: UUID) {
        guard let request = panes.pendingSplit else { return }
        panes.pendingSplit = nil
        var layout = panes.layout
        guard layout.contains(request.target), layout.split(request.target, edge: request.edge, with: tid) else { return }
        commitLayout(layout)
    }

    // MARK: 拖放

    /// 侧栏的会话行（"row:term:<uuid>"）或窗格标题条（终端 id）能否放到某个窗格的某个落点。
    /// 已显示在别的窗格里的：中间为互换，四边为挪过去（按挪走之后的大小判断放不放得下）。
    func canDrop(_ tid: UUID, on target: UUID?, zone: PaneDropZone) -> Bool {
        guard pool.terminal(tid) != nil else { return false }
        guard let target else { return panes.layout.isEmpty }
        switch zone {
        case .center: return target != tid
        case .edge(let edge):
            guard target != tid else { return false }
            if panes.layout.contains(tid) {
                return panes.layout.canMove(tid, beside: target, edge: edge, in: panes.areaSize,
                                            minPane: PaneLayoutModel.minPane)
            }
            return panes.canSplit(target, edge: edge)
        }
    }

    /// 把会话放到窗格上：四边分屏（已显示在别处时挪过去），中间替换（已显示在别处时互换）。
    @discardableResult
    func drop(_ tid: UUID, on target: UUID?, zone: PaneDropZone) -> Bool {
        guard canDrop(tid, on: target, zone: zone) else { return false }
        undockIfDetached(tid)
        var layout = panes.layout
        switch (target, zone) {
        case (nil, _): layout.show(tid)
        case (let target?, .center): layout.replace(target, with: tid)
        case (let target?, .edge(let edge)):
            let placed = layout.contains(tid) ? layout.move(tid, beside: target, edge: edge)
                : layout.split(target, edge: edge, with: tid)
            guard placed else { return false }
        }
        commitLayout(layout)
        selectTerminal(tid)
        focusSelectedTerminal()
        return true
    }

    /// 侧栏拖动内容里的终端 id（"row:term:<uuid>"）。
    static func draggedTerminalID(_ payload: String) -> UUID? {
        let prefix = "row:term:"
        guard payload.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(prefix.count)))
    }

    // MARK: 关闭窗格

    /// 关闭窗格（⌥⌘W / 标题条 ×）：只是不再显示，会话不结束。只剩一个窗格时不关。
    func closePane(_ tid: UUID? = nil) {
        guard let tid = tid ?? panes.layout.focused, panes.layout.isSplit else { return NSSound.beep() }
        var layout = panes.layout
        layout.remove(tid)
        commitLayout(layout)
        if selectedTerminalID == tid || selectedTerminalID == nil { selectTerminal(layout.focused) }
        focusSelectedTerminal()
    }

    /// 终端被移除（会话关闭 / 结束）：窗格收拢；选中的是它时选中接替的窗格。
    func layoutTerminalRemoved(_ tid: UUID) {
        let wasSelected = selectedTerminalID == tid
        detachedTerminalRemoved(tid)
        var layout = panes.layout
        layout.remove(tid)
        commitLayout(layout, save: false)
        if wasSelected { selectTerminal(layout.focused) }
    }

    /// 启动恢复：用保存的布局（去掉没能恢复的终端）。
    func restoreLayout(_ saved: PaneLayout?) {
        guard var layout = saved else { return }
        layout.normalize(keeping: Set(pool.terminals.map(\.id)))
        panes.layout = layout
    }
}
