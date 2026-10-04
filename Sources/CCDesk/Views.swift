import SwiftUI
import AppKit
import CCDeskCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themes = ThemeStore.shared
    /// 侧栏是否收起：收起时窗口按钮与侧栏开关挤到详情区的工具栏这一行，标题栏要让出位置。
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            DetailView(model: model, sidebarCollapsed: columnVisibility == .detailOnly)
        }
        .overlay {
            if model.showHistoryPalette { HistoryPalette(model: model) }
        }
        .overlay { PanePickerSlot(model: model, panes: model.panes) }
        .sheet(isPresented: $model.showNewSession) { NewSessionSheet(model: model) }
        .modifier(AssistantResultsPresenter(work: model.work))
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
        .onChange(of: colorScheme, initial: true) { _, scheme in model.pool.apply(themes.theme(for: scheme).terminal) }
    }
}

/// 详情区：标题栏（放在窗口工具栏里，与侧栏顶部同高）+ 铺满的内嵌终端。
struct DetailView: View {
    @ObservedObject var model: AppModel
    /// 侧栏已收起：左上角的红绿灯和侧栏开关占用了工具栏这一行的开头。
    var sidebarCollapsed = false
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themes = ThemeStore.shared
    /// 详情区宽度，用于限制标题宽度：长标题截断，不把右侧的状态胶囊挤走。
    @State private var width: CGFloat = 0

    /// 工具栏这一行开头被系统占用的宽度：两侧留白；侧栏收起时再加上红绿灯（约 70pt）和侧栏开关（约 50pt）。
    private var leadingChrome: CGFloat { sidebarCollapsed ? 160 : 40 }

    /// 给胶囊（约 90pt）、麦克风按钮（约 34pt）和两侧留白预留空间；宽度未知时沿用 520。
    private var titleMaxWidth: CGFloat {
        guard width > 0 else { return 520 }
        return min(520, max(120, width - 184 - leadingChrome))
    }

    /// 标题栏这一行的宽度：详情区宽度减去开头被占用的部分；不超过实际可用的宽度，否则整项会被收进「>>」溢出菜单。
    private var toolbarRowWidth: CGFloat {
        guard width > 0 else { return 600 }
        return max(0, width - leadingChrome)
    }

    var body: some View {
        let theme = themes.theme(for: colorScheme)
        let row = model.selectedRow.flatMap { $0.session.host.isEmbedded ? $0 : nil }
        VStack(spacing: 0) {
            theme.line.frame(height: 1)
            HStack(spacing: 0) {
                ZStack {
                    PaneArea(model: model, panes: model.panes, theme: theme)
                    VoiceOverlay(voice: model.voice, theme: theme)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 16)
                }
                .background(Color(nsColor: theme.terminal.background))
                if row?.session.kind.isAgent == true {
                    TouchedFilesSlot(files: model.touchedFiles, theme: theme)
                }
            }
            if row != nil {
                VoiceBar(voice: model.voice, conversation: model.conversation, theme: theme)
            }
        }
        .background(theme.main.ignoresSafeArea())
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, new in width = new }
        })
        .onChange(of: Self.touchedKey(row), initial: true) { _, _ in model.touchedFiles.select(row: row) }
        // 标题栏底色跟随主题（不直接改 NSWindow 的底色 / 标题栏样式：那样会让整个工具栏消失）。
        .toolbarBackground(theme.main, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            // 标题在左（navigation）；状态胶囊用 .automatic 放在工具栏最右侧。
            // macOS 上 .primaryAction 会被放在工具栏前端、紧挨标题，所以不用它。
            // 标题在左；状态胶囊和「改动的文件」开关固定在标题栏最右端（与左上角的侧栏开关对称），
            // 位置不随标题长短移动。macOS 14 的工具栏没有弹性间距，所以让这一项撑满详情区宽度。
            ToolbarItem(placement: .navigation) {
                if let row {
                    HStack(spacing: 6) {
                        DetailTitle(row: row, theme: theme, maxWidth: titleMaxWidth)
                        Spacer(minLength: 12)
                        ConversationBadge(conversation: model.conversation, theme: theme)
                        StatusPill(status: row.session.status, label: row.statusLabel, missing: false,
                                   unread: row.showsUnread, theme: theme)
                        if row.session.kind.isAgent {
                            TouchedFilesToggle(files: model.touchedFiles, theme: theme)
                        }
                    }
                    .frame(width: toolbarRowWidth)
                }
            }
        }
    }
}

extension DetailView {
    /// 「改动的文件」跟踪的会话标识：种类 + sessionId + cwd 任一变化就重新加载。
    static func touchedKey(_ row: SidebarRow?) -> String {
        guard let row else { return "" }
        return "\(row.session.kind.rawValue)|\(row.session.sessionID ?? "")|\(row.session.cwd)"
    }
}

/// 面板的显示 / 隐藏（单独观察 TouchedFilesModel，开关时不重绘整个详情区）。
/// 相对时间只精确到分钟：用每分钟走一次的时钟，不跟着每秒的轮询重绘。
struct TouchedFilesSlot: View {
    @ObservedObject var files: TouchedFilesModel
    let theme: Theme

    var body: some View {
        if files.isShown {
            HStack(spacing: 0) {
                PanelDivider(files: files, theme: theme)
                TimelineView(.everyMinute) { context in
                    TouchedFilesPanel(files: files, now: context.date, theme: theme)
                }
            }
            .transition(.move(edge: .trailing))
        }
    }
}

/// 终端与「改动的文件」之间的分隔线：可拖动调整面板宽度，拖得很窄时收起面板。
struct PanelDivider: View {
    @ObservedObject var files: TouchedFilesModel
    let theme: Theme
    @State private var startWidth: CGFloat?

    var body: some View {
        theme.line
            .frame(width: 1)
            .overlay {
                // 实际可拖动的区域比 1pt 宽，方便抓取。光标用 AppKit 的光标区域（不用 push / pop，不会失衡）。
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .background(ResizeCursorArea())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = startWidth ?? files.panelWidth
                            if startWidth == nil { startWidth = start }
                            let proposed = start - value.translation.width
                            files.panelWidth = min(max(proposed, TouchedFilesModel.minWidth), TouchedFilesModel.maxWidth)
                        }
                        .onEnded { value in
                            let proposed = (startWidth ?? files.panelWidth) - value.translation.width
                            startWidth = nil
                            if proposed < TouchedFilesModel.collapseWidth {
                                withAnimation(.easeInOut(duration: 0.18)) { files.isShown = false }
                            }
                        })
            }
    }
}

/// 左右调整大小的光标区域：NSView 的 cursor rect 由窗口管理，进出 / 视图消失都不需要配对的 push / pop。
/// 不接收鼠标事件（hitTest 返回 nil），拖动仍由 SwiftUI 的手势处理。
struct ResizeCursorArea: NSViewRepresentable {
    var cursor: NSCursor = .resizeLeftRight

    final class CursorView: NSView {
        var cursor: NSCursor = .resizeLeftRight

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> CursorView { CursorView() }

    func updateNSView(_ view: CursorView, context: Context) {
        view.cursor = cursor
        view.window?.invalidateCursorRects(for: view)
    }
}

struct DetailTitle: View {
    let row: SidebarRow
    let theme: Theme
    var maxWidth: CGFloat = 520

    var body: some View {
        let path = row.session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        VStack(alignment: .leading, spacing: 0) {
            Text(row.displayName)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(theme.fg1)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 18)
            Text(row.session.kind.isAgent ? "\(row.session.kind.displayName) · \(path)" : path)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.fg2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 15)
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .help(row.tooltip)
    }
}

/// 状态胶囊（详情区标题栏右侧）。
struct StatusPill: View {
    let status: AgentStatus
    /// 显示文字（如内嵌普通 shell 的「终端」）；nil 时取 status.label。
    var label: String? = nil
    let missing: Bool
    /// 已完成·未读：鼠尾草绿「已完成」（等批准优先）。
    var unread: Bool = false
    let theme: Theme

    var body: some View {
        let (bg, fg, label) = colors
        HStack(spacing: 5) {
            if status == .working && !missing { BreathingDot(color: theme.dot, size: 6) }
            Text(label).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Capsule().fill(bg))
    }

    private var colors: (Color, Color, String) {
        if missing { return (theme.pillMissBg, theme.pillMissFg, L("status.directoryMissing")) }
        if unread && !status.isWaiting { return (theme.chipUnreadBg, theme.chipUnreadFg, L("status.done")) }
        switch status {
        case .waiting: return (theme.pillWaitBg, theme.pillWaitFg, label ?? status.label)
        case .working: return (theme.pillWorkBg, theme.pillWorkFg, label ?? status.label)
        case .idle, .ended, .unknown: return (theme.pillIdleBg, theme.pillIdleFg, label ?? status.label)
        }
    }
}

struct NewSessionSheet: View {
    @ObservedObject var model: AppModel
    @State private var kind: AgentKind = .claude

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("newSession.title", kind.displayName)).font(.headline)
                Spacer()
                CloseButton { model.showNewSession = false }
            }
            AgentPicker(model: model, selection: $kind)
            if model.recentDirs.isEmpty {
                Text(L("newSession.noRecent")).foregroundStyle(.secondary)
            } else {
                Text(L("newSession.recent")).font(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(model.recentDirs.enumerated()), id: \.element) { index, dir in
                    Button {
                        model.showNewSession = false
                        model.newSession(cwd: dir, kind: kind)
                    } label: {
                        Text(dir.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .keyboardShortcut(index == 0 ? .defaultAction : nil)
                }
            }
            HStack {
                Button(L("newSession.chooseOther")) { model.chooseDirectoryAndCreate(kind: kind) }
                Spacer()
                Button(L("action.cancel")) { model.showNewSession = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            kind = model.lastAgent
            model.probeAgents()
        }
        // 从分屏面板打开的表单：关掉时（无论是否新建）不再把之后的新建放进那个分屏。
        .onDisappear { model.panes.pendingSplit = nil }
        .onChange(of: model.installedAgents) { _, _ in
            // 检测完成后上次的 agent 已不可用（如被卸载）：退回 Claude。
            if !model.availability(of: kind).isEnabled, model.installedAgents != nil { kind = .claude }
        }
    }
}

/// 新建会话的 agent 选择：Claude / Codex / pi；本机未安装（或尚在检测）的选项置灰并标注原因。
struct AgentPicker: View {
    @ObservedObject var model: AppModel
    @Binding var selection: AgentKind

    var body: some View {
        HStack(spacing: 6) {
            Text(L("newSession.agent")).foregroundStyle(.secondary)
            ForEach(AgentKind.launchable, id: \.self) { kind in
                let availability = model.availability(of: kind)
                Button {
                    selection = kind
                } label: {
                    HStack(spacing: 4) {
                        Text(kind.displayName)
                        if let hint = availability.hint {
                            Text(hint).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(
                        selection == kind ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                        selection == kind ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!availability.isEnabled)
                .help(availability.hint.map { L("agentPicker.unavailable.help", kind.displayName, $0) } ?? L("agentPicker.use.help", kind.displayName))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }
}

/// 目录行「+」的右键菜单：选择 agent 新建（直接点击「+」用上次使用的 agent）。
struct AgentLaunchMenu: View {
    @ObservedObject var model: AppModel
    let cwd: String

    var body: some View {
        ForEach(AgentKind.launchable, id: \.self) { kind in
            let availability = model.availability(of: kind)
            Button {
                model.newSession(cwd: cwd, kind: kind)
            } label: {
                Text(availability.hint.map { L("agentMenu.unavailable", kind.displayName, $0) } ?? L("newSession.title", kind.displayName))
            }
            .disabled(!availability.isEnabled)
        }
    }
}
