import SwiftUI
import AppKit
import CCDeskCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            DetailView(model: model)
        }
        .overlay {
            if model.showHistoryPalette { HistoryPalette(model: model) }
        }
        .sheet(isPresented: $model.showNewSession) { NewSessionSheet(model: model) }
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
        .onChange(of: colorScheme, initial: true) { _, scheme in model.pool.apply(Theme.of(scheme).terminal) }
    }
}

/// 详情区：标题栏（放在窗口工具栏里，与侧栏顶部同高）+ 铺满的内嵌终端。
struct DetailView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    /// 详情区宽度，用于限制标题宽度：长标题截断，不把右侧的状态胶囊挤走。
    @State private var width: CGFloat = 0

    /// 给胶囊（约 90pt）和两侧留白预留空间；宽度未知时沿用 520。
    private var titleMaxWidth: CGFloat {
        guard width > 0 else { return 520 }
        return min(520, max(120, width - 190))
    }

    var body: some View {
        let theme = Theme.of(colorScheme)
        let row = model.selectedRow.flatMap { $0.session.host.isEmbedded ? $0 : nil }
        VStack(spacing: 0) {
            theme.line.frame(height: 1)
            ZStack {
                TerminalContainer(pool: model.pool, terminalIDs: model.pool.terminals.map(\.id),
                                  selected: model.selectedTerminalID, background: theme.terminal.background)
                if model.selectedTerminalID == nil {
                    Text("选择左侧的 session，或按 ⌘N 新建")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.fg3)
                }
            }
            .background(Color(nsColor: theme.terminal.background))
        }
        .background(theme.main.ignoresSafeArea())
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, new in width = new }
        })
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            // 标题在左（navigation）；状态胶囊用 .automatic 放在工具栏最右侧。
            // macOS 上 .primaryAction 会被放在工具栏前端、紧挨标题，所以不用它。
            ToolbarItem(placement: .navigation) {
                if let row { DetailTitle(row: row, theme: theme, maxWidth: titleMaxWidth) }
            }
            ToolbarItem(placement: .automatic) {
                if let row {
                    StatusPill(status: row.session.status, label: row.statusLabel, missing: false,
                               unread: row.showsUnread, theme: theme)
                }
            }
        }
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
        if missing { return (theme.pillMissBg, theme.pillMissFg, "目录缺失") }
        if unread && !status.isWaiting { return (theme.chipUnreadBg, theme.chipUnreadFg, "已完成") }
        switch status {
        case .waiting: return (theme.pillWaitBg, theme.pillWaitFg, label ?? status.label)
        case .working: return (theme.pillWorkBg, theme.pillWorkFg, label ?? status.label)
        case .idle, .ended, .unknown: return (theme.pillIdleBg, theme.pillIdleFg, label ?? status.label)
        }
    }
}

/// 所有内嵌终端视图常驻同一个容器，切换只改 isHidden，不重建、不清屏。
/// 容器四周留出与标题栏一致的内边距（左右 24pt、上下 20pt），底色与终端一致。
struct TerminalContainer: NSViewRepresentable {
    let pool: TerminalPool
    let terminalIDs: [UUID]
    let selected: UUID?
    let background: NSColor

    final class Coordinator {
        var lastSelected: UUID?
    }

    /// 按固定内边距布局所有子视图（终端）。
    final class HostView: NSView {
        static let insets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        override func layout() {
            super.layout()
            let insets = Self.insets
            let frame = NSRect(x: insets.left, y: insets.bottom,
                               width: max(0, bounds.width - insets.left - insets.right),
                               height: max(0, bounds.height - insets.top - insets.bottom))
            for view in subviews { view.frame = frame }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ container: HostView, context: Context) {
        container.layer?.backgroundColor = background.cgColor
        let views = pool.terminals.map(\.view)
        var added = false
        for view in views where view.superview !== container {
            container.addSubview(view)
            added = true
        }
        for view in container.subviews where !views.contains(where: { $0 === view }) {
            view.removeFromSuperview()
        }
        if added { container.needsLayout = true }
        for terminal in pool.terminals {
            terminal.view.isHidden = terminal.id != selected
        }
        if context.coordinator.lastSelected != selected {
            context.coordinator.lastSelected = selected
            if let id = selected, let terminal = pool.terminal(id) {
                DispatchQueue.main.async { terminal.view.window?.makeFirstResponder(terminal.view) }
            }
        }
    }
}

struct NewSessionSheet: View {
    @ObservedObject var model: AppModel
    @State private var kind: AgentKind = .claude

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建 \(kind.displayName) 会话").font(.headline)
            AgentPicker(model: model, selection: $kind)
            if model.recentDirs.isEmpty {
                Text("还没有最近使用的目录").foregroundStyle(.secondary)
            } else {
                Text("最近使用").font(.subheadline).foregroundStyle(.secondary)
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
                Button("选择其他目录…") { model.chooseDirectoryAndCreate(kind: kind) }
                Spacer()
                Button("取消") { model.showNewSession = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            kind = model.lastAgent
            model.probeAgents()
        }
    }
}

/// 新建会话的 agent 选择：Claude / Codex / pi；尚不能启动的选项置灰并标注原因（未安装 / 即将支持）。
struct AgentPicker: View {
    @ObservedObject var model: AppModel
    @Binding var selection: AgentKind

    var body: some View {
        HStack(spacing: 6) {
            Text("Agent").foregroundStyle(.secondary)
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
                .help(availability.hint.map { "\(kind.displayName)：\($0)" } ?? "使用 \(kind.displayName)")
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
                Text(availability.hint.map { "\(kind.displayName)（\($0)）" } ?? "新建 \(kind.displayName) 会话")
            }
            .disabled(!availability.isEnabled)
        }
    }
}
