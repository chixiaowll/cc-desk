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
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.fg3)
                }
            }
            SidebarFooter(rows: groups.flatMap(\.rows), usage: model.claudeUsage, now: clock.now, theme: theme,
                          onOpenUsage: { model.refreshUsageNow() })
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
            ToolbarItem { AssistantResultsButton(work: model.work) }
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
                                       detached: row.session.host.terminalID.map(model.isDetached) ?? false)
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

    private var allMissing: Bool {
        group.rows.allSatisfy {
            if case .missing = $0.session.host { return true }
            return false
        }
    }

    private var showActions: Bool { hovering || showHistory }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.fg2)
                    .frame(width: 30)
                HStack(spacing: 6) {
                    Text(group.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.fg1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if let branch = group.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.fg3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            GroupCounts(group: group, collapsed: collapsed, theme: theme)
                .opacity(showActions ? 0 : 1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.fg3)
                .rotationEffect(.degrees(collapsed ? -90 : 0))
                .animation(.easeInOut(duration: 0.15), value: collapsed)
                .frame(width: 16)
        }
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8).fill(showActions ? theme.hover : Color.clear))
        .overlay(alignment: .trailing) {
            if showActions {
                actions.padding(.trailing, 22)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .onHover { hovering = $0 }
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

/// 目录行右侧的状态计数：等批准实心橙、已完成·未读实心鼠尾草绿、处理中实心雾蓝带呼吸白点、空闲灰色（仅收起时）。
struct GroupCounts: View {
    let group: SessionGroup
    let collapsed: Bool
    let theme: Theme

    var body: some View {
        HStack(spacing: 3) {
            if group.waitingCount > 0 {
                CountChip(text: "\(group.waitingCount)", bg: theme.pillWaitBg, fg: theme.pillWaitFg)
            }
            if group.unreadCount > 0 {
                CountChip(text: "\(group.unreadCount)", bg: theme.chipUnreadBg, fg: theme.chipUnreadFg)
            }
            if group.workingCount > 0 {
                HStack(spacing: 4) {
                    BreathingDot(color: theme.chipWorkFg, size: 5)
                    Text("\(group.workingCount)")
                }
                .modifier(CountChipStyle(bg: theme.chipWorkBg, fg: theme.chipWorkFg, leading: 5, trailing: 6))
            }
            if collapsed && group.idleCount > 0 {
                CountChip(text: "\(group.idleCount)", bg: theme.chip, fg: theme.fg2)
            }
        }
        .fixedSize()
        .help(helpText)
    }

    private var helpText: String {
        [group.waitingCount > 0 ? L("group.help.waiting", group.waitingCount) : nil,
         group.unreadCount > 0 ? L("group.help.unread", group.unreadCount) : nil,
         group.workingCount > 0 ? L("group.help.working", group.workingCount) : nil,
         group.idleCount > 0 ? L("group.help.idle", group.idleCount) : nil]
            .compactMap { $0 }
            .joined(separator: L("list.separator.clause"))
    }
}

struct CountChip: View {
    let text: String
    let bg: Color
    let fg: Color

    var body: some View {
        Text(text).modifier(CountChipStyle(bg: bg, fg: fg, leading: 5, trailing: 5))
    }
}

struct CountChipStyle: ViewModifier {
    let bg: Color
    let fg: Color
    let leading: CGFloat
    let trailing: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(fg)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .frame(minWidth: 16, minHeight: 16, maxHeight: 16)
            .background(Capsule().fill(bg))
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

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(on ? theme.fg1 : theme.fg2)
                .frame(width: 22, height: 22)
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
    var onOpenUsage: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if let usage, !usage.footerLimits.isEmpty {
                UsageFooterLine(usage: usage, now: now, theme: theme, onOpen: onOpenUsage)
                    .padding(.horizontal, 18)
                    .padding(.top, 9)
                    .frame(height: 26)
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
        .font(.system(size: 11.5))
        .foregroundStyle(theme.fg2)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: hasUsage ? 32 : 40, maxHeight: hasUsage ? 32 : 40, alignment: .leading)
    }

    private var separator: some View {
        theme.line.frame(width: 1, height: 10).padding(.horizontal, 4)
    }
}
