import SwiftUI
import AppKit
import CCDeskCore

/// 侧栏：自绘的目录分组 + 会话行（ScrollView + LazyVStack，以便精确控制间距与悬停），底部汇总。
struct SidebarView: View {
    @ObservedObject var model: AppModel
    /// 每秒走一次的时钟（会话行的相对时间）；只有侧栏观察它。
    @ObservedObject private var clock: AppClock
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themes = ThemeStore.shared

    init(model: AppModel) {
        self.model = model
        _clock = ObservedObject(wrappedValue: model.clock)
    }

    var body: some View {
        let theme = themes.theme(for: colorScheme)
        let groups = model.groups
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        let collapsed = model.collapsed.contains(group.id)
                        let previousExpanded = index > 0 && !model.collapsed.contains(groups[index - 1].id)
                        GroupSectionView(model: model, group: group, collapsed: collapsed, now: clock.now, theme: theme)
                            .padding(.top, previousExpanded ? 2 : 0)
                            .padding(.bottom, collapsed ? 0 : 8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .overlay {
                if groups.isEmpty {
                    Text(L("sidebar.empty"))
                        .uiFont(size: 12)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.fg3)
                }
            }
            SidebarFooter(rows: groups.flatMap(\.rows), usage: model.claudeUsage, now: clock.now, theme: theme,
                          tokens: model.tokenOverview,
                          onOpenUsage: { model.refreshUsageNow(); model.refreshTokens(force: true) })
        }
        .background(theme.side.ignoresSafeArea())
        .toolbar {
            ToolbarItem {
                Button { model.showNewSession = true } label: { Image(systemName: "plus") }
                    .help(L("toolbar.newSession.help"))
            }
            ToolbarItem {
                Button { model.showHistoryPalette = true } label: { Image(systemName: "clock") }
                    .help(L("toolbar.history.help"))
            }
            ToolbarItem {
                Button { model.skills.showWindow() } label: { Image(systemName: "books.vertical") }
                    .help(L("toolbar.skills.help"))
            }
            ToolbarItem { AssistantResultsButton(work: model.work, companion: model.companion) }
        }
    }
}

/// 一个目录分组：28pt 目录行 + （展开时）缩进 16pt 的会话行。
struct GroupSectionView: View {
    @ObservedObject var model: AppModel
    let group: SessionGroup
    let collapsed: Bool
    let now: Date
    let theme: Theme
    @AppStorage(SidebarModelPreference.defaultsKey) private var showModel = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeaderView(model: model, group: group, collapsed: collapsed, theme: theme)
            if !collapsed {
                let showAgentLabel = model.showAgentLabel
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(group.rows) { row in
                        SessionRowView(row: row, selected: row.id == model.selectedID, now: now,
                                       appIcon: HostApps.icon(appPath: model.hostAppPaths[row.id], host: row.session.host),
                                       theme: theme,
                                       onResume: row.session.host.isEmbedded && row.session.status == .ended
                                           && !model.isResumingEnded(row) ? { model.resumeEnded(row) } : nil,
                                       showAgentLabel: showAgentLabel,
                                       showModel: showModel,
                                       detached: row.session.host.terminalID.map(model.isDetached) ?? false,
                                       shortcut: model.commandHeld ? model.shortcutNumber(of: row.id) : nil,
                                       tokens: model.tokenTooltip(for: row))
                            .onTapGesture { model.activate(row) }
                            .contextMenu {
                                RowMenu(model: model, row: row)
                                if group.rows.count > 1 {
                                    Divider()
                                    MoveMenu { model.moveRow(row, $0) }
                                }
                            }
                            .draggable("row:\(row.id)")
                            .dropDestination(for: String.self) { items, _ in
                                items.first.map { model.dropForReorder($0, ontoGroup: nil, ontoRow: row.id) } ?? false
                            }
                    }
                }
                .padding(.leading, 16)
            }
        }
    }
}

/// 右键菜单「移动」：移到最上 / 上移 / 下移 / 移到最下（也可以直接拖拽）。
struct MoveMenu: View {
    let action: (SidebarOrder.Move) -> Void

    var body: some View {
        Menu(L("sidebar.move")) {
            Button(L("sidebar.move.top")) { action(.top) }
            Button(L("sidebar.move.up")) { action(.up) }
            Button(L("sidebar.move.down")) { action(.down) }
            Button(L("sidebar.move.bottom")) { action(.bottom) }
        }
    }
}

/// 目录行：整行点击切换折叠；悬停时历史 / 新建按钮浮在计数位置上（不重排、不挤压名字）。
struct GroupHeaderView: View {
    @ObservedObject var model: AppModel
    let group: SessionGroup
    let collapsed: Bool
    let theme: Theme
    @State private var hovering = false
    @State private var showHistory = false
    @Environment(\.uiScale) private var uiScale

    private var allMissing: Bool {
        group.rows.allSatisfy {
            if case .missing = $0.session.host { return true }
            return false
        }
    }

    private var showActions: Bool { hovering || showHistory }

    var body: some View {
        GroupHeaderLabel(group: group, collapsed: collapsed, countsHidden: showActions, theme: theme)
        .background(RoundedRectangle(cornerRadius: 8).fill(showActions ? theme.hover : Color.clear))
        .overlay(alignment: .trailing) {
            if showActions {
                actions.padding(.trailing, uiScale.metric(22))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .onHover { hovering = $0 }
        .overlay(alignment: .trailing) {
            // 收起的组：按住 ⌘ 时把组里会话的编号显示在组标题上。
            if collapsed, model.commandHeld {
                let numbers = group.rows.compactMap { model.shortcutNumber(of: $0.id) }
                if !numbers.isEmpty {
                    Text(numbers.map { "⌘\($0)" }.joined(separator: " "))
                        .uiFont(size: 11, weight: .semibold, monospacedDigit: true)
                        .foregroundStyle(theme.chipWorkFg)
                        .padding(.horizontal, 6)
                        .frame(height: uiScale.metric(18))
                        .background(Capsule().fill(theme.accent))
                        .padding(.trailing, uiScale.metric(26))
                }
            }
        }
        .help(group.id.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        .contextMenu {
            MoveMenu { model.moveGroup(group.id, $0) }
        }
        .draggable("group:\(group.id)")
        .dropDestination(for: String.self) { items, _ in
            items.first.map { model.dropForReorder($0, ontoGroup: group.id, ontoRow: nil) } ?? false
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if !model.history(forRoot: group.id).isEmpty {
                SidebarIconButton(systemName: "clock", help: L("sidebar.history.help"), on: showHistory, theme: theme) {
                    if !showHistory { model.refreshHistory() }
                    showHistory.toggle()
                }
                .popover(isPresented: $showHistory, arrowEdge: .trailing) {
                    HistoryPopover(
                        model: model, root: group.id, title: group.title,
                        onSearchAll: {
                            showHistory = false
                            model.showHistoryPalette = true
                        },
                        onResume: { item in
                            showHistory = false
                            model.resumeHistory(item)
                        })
                    .uiScaleRoot()
                }
            }
            if !allMissing {
                SidebarIconButton(systemName: "plus",
                                  help: L("sidebar.newInGroup.help", group.title, model.lastAgent.displayName),
                                  theme: theme) {
                    model.newSession(cwd: group.id)
                }
                .contextMenu { AgentLaunchMenu(model: model, cwd: group.id) }
                .onAppear { model.probeAgents() }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 4)
        .frame(maxHeight: .infinity)
        .background(
            HStack(spacing: 0) {
                LinearGradient(colors: [theme.hover.opacity(0), theme.hover], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 16)
                theme.hover
            })
    }

    private func toggle() {
        if collapsed { model.collapsed.remove(group.id) } else { model.collapsed.insert(group.id) }
    }
}

/// 22pt 图标按钮（目录行上的历史 / 新建）；`on` 表示对应的弹出层已打开。
struct SidebarIconButton: View {
    let systemName: String
    let help: String
    var on: Bool = false
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .uiFont(size: 12)
                .foregroundStyle(on ? theme.fg1 : theme.fg2)
                .frame(width: uiScale.metric(22), height: uiScale.metric(22))
                .background(RoundedRectangle(cornerRadius: 6).fill(
                    on ? theme.fg1.opacity(0.08) : (hovering ? theme.chip : Color.clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 底部汇总：（有 Claude 用量缓存时）上方一行用量，下方「N 个会话 | ●N 处理中 | ●N 待处理 | ●N 未读」，0 时省略对应段。
struct SidebarFooter: View {
    let rows: [SidebarRow]
    let usage: ClaudeUsage?
    let now: Date
    let theme: Theme
    var tokens: TokenOverview? = nil
    var onOpenUsage: () -> Void = {}
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        VStack(spacing: 0) {
            if let usage, !usage.footerLimits.isEmpty {
                UsageFooterLine(usage: usage, now: now, theme: theme, tokens: tokens, onOpen: onOpenUsage)
                    .padding(.horizontal, 18)
                    .padding(.top, 9)
                    .frame(height: uiScale.metric(26))
            } else if let tokens, !tokens.isEmpty {
                // 没有 Claude 订阅用量（只用 Codex / pi 等）时，底部只显示 token 汇总。
                TokenFooterLine(tokens: tokens, theme: theme, onOpen: onOpenUsage)
                    .padding(.horizontal, 18)
                    .padding(.top, 9)
                    .frame(height: uiScale.metric(26))
            }
            counts
        }
        .overlay(alignment: .top) { theme.line.frame(height: 1) }
    }

    private var hasUsage: Bool { !(usage?.footerLimits.isEmpty ?? true) }

    private var counts: some View {
        let working = rows.filter { $0.session.status == .working }.count
        let waiting = rows.filter { $0.session.status.isWaiting }.count
        let unread = rows.filter(\.showsUnread).count
        return HStack(spacing: 6) {
            Text(LN("footer.sessions", rows.count))
            if working > 0 {
                separator
                Circle().fill(theme.dot).frame(width: 6, height: 6)
                Text(L("footer.working", working))
            }
            if waiting > 0 {
                separator
                Circle().fill(theme.pillWaitBg).frame(width: 6, height: 6)
                Text(L("footer.waiting", waiting)).fontWeight(.semibold).foregroundStyle(theme.accent)
            }
            if unread > 0 {
                separator
                Circle().fill(theme.unread).frame(width: 6, height: 6)
                Text(L("footer.unread", unread)).fontWeight(.medium).foregroundStyle(theme.unread)
            }
        }
        .uiFont(size: 11.5)
        .foregroundStyle(theme.fg2)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: uiScale.metric(hasUsage ? 32 : 40),
               maxHeight: uiScale.metric(hasUsage ? 32 : 40), alignment: .leading)
    }

    private var separator: some View {
        theme.line.frame(width: 1, height: 10).padding(.horizontal, 4)
    }
}
