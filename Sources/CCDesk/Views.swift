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
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if let row { DetailTitle(row: row, theme: theme) }
            }
            ToolbarItem(placement: .primaryAction) {
                if let row { StatusPill(status: row.session.status, missing: false, theme: theme) }
            }
        }
    }
}

struct DetailTitle: View {
    let row: SidebarRow
    let theme: Theme

    var body: some View {
        let path = row.session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        VStack(alignment: .leading, spacing: 0) {
            Text(row.displayName)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(theme.fg1)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 18)
            Text(row.session.kind == .claude ? "Claude · \(path)" : path)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.fg2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: 15)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .help(row.tooltip)
    }
}

/// 状态胶囊（详情区标题栏右侧）。
struct StatusPill: View {
    let status: AgentStatus
    let missing: Bool
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
        switch status {
        case .waiting: return (theme.pillWaitBg, theme.pillWaitFg, status.label)
        case .working: return (theme.pillWorkBg, theme.pillWorkFg, status.label)
        case .idle, .unknown: return (theme.pillIdleBg, theme.pillIdleFg, status.label)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建 Claude Code Session").font(.headline)
            if model.recentDirs.isEmpty {
                Text("还没有最近使用的目录").foregroundStyle(.secondary)
            } else {
                Text("最近使用").font(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(model.recentDirs.enumerated()), id: \.element) { index, dir in
                    Button {
                        model.showNewSession = false
                        model.newSession(cwd: dir)
                    } label: {
                        Text(dir.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .keyboardShortcut(index == 0 ? .defaultAction : nil)
                }
            }
            HStack {
                Button("选择其他目录…") { model.chooseDirectoryAndCreate() }
                Spacer()
                Button("取消") { model.showNewSession = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
