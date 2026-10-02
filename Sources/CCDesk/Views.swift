import SwiftUI
import AppKit
import CCDeskCore

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            DetailView(model: model)
        }
        .sheet(isPresented: $model.showNewSession) { NewSessionSheet(model: model) }
    }
}

struct StatusIcon: View {
    let status: AgentStatus

    var body: some View {
        switch status {
        case .waiting: Text("▲").foregroundStyle(.orange)
        case .working: Text("●").foregroundStyle(.blue)
        case .idle: Text("○").foregroundStyle(.secondary)
        case .unknown: Text("?").foregroundStyle(.secondary)
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            ForEach(model.groups) { group in
                Section {
                    if !model.collapsed.contains(group.id) {
                        ForEach(group.rows) { row in
                            RowView(row: row, selected: row.id == model.selectedID, now: model.now)
                                .contentShape(Rectangle())
                                .onTapGesture { model.activate(row) }
                                .contextMenu { RowMenu(model: model, row: row) }
                        }
                    }
                } header: {
                    GroupHeader(model: model, group: group)
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button { model.showNewSession = true } label: { Image(systemName: "plus") }
                    .help("新建 Session（⌘N）")
            }
        }
        .overlay {
            if model.groups.isEmpty {
                Text("没有运行中的 Claude Code session\n⌘N 新建").multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
        }
    }
}

struct GroupHeader: View {
    @ObservedObject var model: AppModel
    let group: SessionGroup

    var body: some View {
        let collapsed = model.collapsed.contains(group.id)
        HStack(spacing: 6) {
            Button { model.toggleCollapsed(group) } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").frame(width: 12)
            }
            .buttonStyle(.plain)
            StatusIcon(status: group.topStatus).font(.caption)
            Text(group.title).font(.headline)
            if collapsed { Text("(\(group.rows.count))").foregroundStyle(.secondary) }
            Spacer()
            Button { model.newSession(cwd: group.id) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .help("在 \(group.id) 新建 Session")
        }
    }
}

struct RowView: View {
    let row: SidebarRow
    let selected: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusIcon(status: row.session.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.displayName).lineLimit(1)
                    if let label = row.sourceLabel {
                        Text("[\(label)]").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let subtitle = row.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Text(row.session.status.label).font(.caption).foregroundStyle(.secondary)
            Text(RelativeTime.short(from: row.session.statusChangedAt, now: now))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .opacity(RelativeTime.isStale(row.session.statusChangedAt, now: now) ? 0.5 : 1)
        .listRowBackground(selected ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}

struct RowMenu: View {
    @ObservedObject var model: AppModel
    let row: SidebarRow

    var body: some View {
        switch row.session.host {
        case .missing:
            Button("在其他目录打开…") { model.relocateMissing(row) }
            Button("移除") { model.removeMissing(row) }
        default:
            Button("在 Finder 中打开") { model.revealInFinder(row) }
            if row.session.sessionID != nil {
                Button("复制恢复命令") { model.copyResumeCommand(row) }
            }
            if !row.session.host.isEmbedded {
                Button("在这里接管") { model.takeOver(row) }
                    .disabled(row.session.sessionID == nil || row.session.pid == nil)
            }
            Divider()
            if row.session.host.isEmbedded {
                Button("关闭") { model.close(row) }
            } else {
                Button("结束进程") { model.killExternal(row) }
            }
        }
    }
}

struct DetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let row = model.selectedRow, row.session.host.isEmbedded {
                HStack {
                    Text(row.displayName).font(.headline)
                    Text("·").foregroundStyle(.secondary)
                    Text(row.session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }
            ZStack {
                TerminalContainer(pool: model.pool, terminalIDs: model.pool.terminals.map(\.id),
                                  selected: model.selectedTerminalID)
                if model.selectedTerminalID == nil {
                    Text("选择左侧的 session，或按 ⌘N 新建").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 所有内嵌终端视图常驻同一个容器，切换只改 isHidden，不重建、不清屏。
struct TerminalContainer: NSViewRepresentable {
    let pool: TerminalPool
    let terminalIDs: [UUID]
    let selected: UUID?

    final class Coordinator {
        var lastSelected: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        let views = pool.terminals.map(\.view)
        for view in views where view.superview !== container {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        for view in container.subviews where !views.contains(where: { $0 === view }) {
            view.removeFromSuperview()
        }
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
